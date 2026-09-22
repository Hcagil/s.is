@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Changing the phone, against the real stack.
///
/// The product rule is two statements at once: history follows the member, and
/// only one device may hold it. Both halves live in the server — messages are
/// stored per conversation, not per device, and `activate_session()` plus
/// `has_app_access()` decide which device is the one that may read them. A
/// fake repository cannot test either: it has no second session to be evicted
/// by, and no row-level security to enforce the eviction.
///
/// So this suite signs the SAME member in twice, on two independent clients,
/// which is exactly what a new phone does: a second row in `auth.sessions`
/// with a later `created_at`.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts (supabase/seed.sql): signing in claims the active device, so
/// sharing a pair with another suite would evict it.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  // Headless: no secure storage to hold a PKCE verifier, and the implicit
  // flow does not need one.
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

/// Signs [email] in on a NEW client — a new `auth.sessions` row, which is what
/// makes it a different device — and optionally claims the active session.
Future<SupabaseClient> signedIn(String email, {bool activate = true}) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  if (activate) {
    expect(
      await client.rpc('activate_session'),
      isTrue,
      reason: 'the newest device must be allowed to claim the session',
    );
  }
  return client;
}

/// The `session_id` claim the whole gate is built on, read from the access
/// token the way the database reads it.
String sessionIdOf(SupabaseClient client) {
  final parts = client.auth.currentSession!.accessToken.split('.');
  final claims = json.decode(
    utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
  ) as Map<String, dynamic>;
  final id = claims['session_id'];
  expect(
    id,
    isA<String>(),
    reason: 'no session_id claim: the single-device gate cannot work at all',
  );
  return id as String;
}

List<String> bodiesOf(Result<List<Message>> result) {
  expect(result, isA<Ok<List<Message>>>(), reason: 'read refused');
  return (result as Ok<List<Message>>).value.map((m) => m.body).toList();
}

void main() {
  final stamp = DateTime.now().microsecondsSinceEpoch;

  SupabaseClient? oldPhoneClient;
  SupabaseClient? newPhoneClient;
  SupabaseClient? frankClient;
  SupabaseClient? graceClient;
  late SupabaseChatRepository oldPhone;
  late SupabaseChatRepository newPhone;
  late SupabaseChatRepository frank;

  late String withFrank;
  late String withGrace;
  late String oldSessionId;

  /// History written before the new phone existed, oldest first.
  final historyWithFrank = <String>[];
  final historyWithGrace = <String>[];

  /// Anything the evicted subscription still delivers. Must stay empty.
  final leakedToOldPhone = <Message>[];
  StreamSubscription<Message>? oldPhoneSub;
  late Stream<Message> frankIncoming;

  setUpAll(() async {
    frankClient = await signedIn('frank@integration.test');
    // Grace only has to exist and be allowlisted; she is the second
    // conversation, so "every conversation" is more than one.
    graceClient = await signedIn('grace@integration.test', activate: false);
    oldPhoneClient = await signedIn('erin@integration.test');
    oldPhone = SupabaseChatRepository(oldPhoneClient!);
    frank = SupabaseChatRepository(frankClient!);
    oldSessionId = sessionIdOf(oldPhoneClient!);

    withFrank = (await oldPhone.startDirectConversation(
      frankClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
    withGrace = (await oldPhone.startDirectConversation(
      graceClient!.auth.currentUser!.id,
    ) as Ok<String>).value;

    // The history that must survive the phone change. Both directions: a
    // device-scoped read would be likeliest to lose what the member did not
    // send themselves.
    for (final body in [
      'erin to frank one $stamp',
      'erin to frank two $stamp',
    ]) {
      expect(
        await oldPhone.send(conversationId: withFrank, body: body),
        isA<Ok<Message>>(),
      );
      historyWithFrank.add(body);
    }
    final fromFrank = 'frank to erin $stamp';
    expect(
      await frank.send(conversationId: withFrank, body: fromFrank),
      isA<Ok<Message>>(),
    );
    historyWithFrank.add(fromFrank);

    final toGrace = 'erin to grace $stamp';
    expect(
      await oldPhone.send(conversationId: withGrace, body: toGrace),
      isA<Ok<Message>>(),
    );
    historyWithGrace.add(toGrace);

    // Subscriptions opened while the old phone is still the active device.
    final opened = await oldPhone.incoming(withFrank);
    expect(opened, isA<Ok<Stream<Message>>>(), reason: 'subscription refused');
    oldPhoneSub = (opened as Ok<Stream<Message>>).value.listen(
      leakedToOldPhone.add,
    );
    frankIncoming =
        (await frank.incoming(withFrank) as Ok<Stream<Message>>).value;

    // The old phone's socket is proven to deliver BEFORE anything is taken
    // away from it. Without this, "it received nothing after the takeover" is
    // satisfied by a subscription that was never working, and the test passes
    // for a reason that has nothing to do with the access gate.
    final ping = 'ping while still active $stamp';
    expect(
      await frank.send(conversationId: withFrank, body: ping),
      isA<Ok<Message>>(),
    );
    historyWithFrank.add(ping);
    final live = DateTime.now().add(const Duration(seconds: 45));
    while (!leakedToOldPhone.any((m) => m.body == ping)) {
      if (DateTime.now().isAfter(live)) {
        fail(
          'the old phone never received anything while it was the active device',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Realtime follows the write-ahead log in order, so once the ping has
    // arrived nothing written before it can still be in flight: from here the
    // buffer must stay empty.
    leakedToOldPhone.clear();

    // The phone change itself: a second sign-in for the same member, which is
    // a later auth.sessions row, claiming the single active session.
    newPhoneClient = await signedIn('erin@integration.test');
    newPhone = SupabaseChatRepository(newPhoneClient!);
    expect(
      sessionIdOf(newPhoneClient!),
      isNot(oldSessionId),
      reason: 'the second sign-in must be a different session',
    );
  });

  tearDownAll(() async {
    await oldPhoneSub?.cancel();
    await oldPhoneClient?.dispose();
    await newPhoneClient?.dispose();
    await frankClient?.dispose();
    await graceClient?.dispose();
  });

  test('the new phone reads history written before it existed', () async {
    // Completeness is the requirement. Order is a separate contract of
    // ChatRepository.messages and is not asserted here.
    expect(
      bodiesOf(await newPhone.messages(withFrank)),
      containsAll(historyWithFrank),
      reason: 'the new device must see the whole conversation, both senders',
    );
  });

  test(
    'the new phone reads every conversation the member belongs to',
    () async {
      expect(
        bodiesOf(await newPhone.messages(withGrace)),
        containsAll(historyWithGrace),
      );

      final listed = await newPhone.conversations();
      expect(listed, isA<Ok<List<Conversation>>>());
      final byId = {
        for (final c in (listed as Ok<List<Conversation>>).value) c.id: c,
      };
      expect(byId.keys, containsAll([withFrank, withGrace]));
      expect(
        byId[withFrank]!.lastMessage,
        historyWithFrank.last,
        reason:
            'the preview is the newest message, not the newest this device saw',
      );
      expect(byId[withGrace]!.lastMessageAt, isNotNull);
    },
  );

  test('the new phone can send, and the other member reads it', () async {
    final body = 'from the new phone $stamp';
    expect(
      await newPhone.send(conversationId: withFrank, body: body),
      isA<Ok<Message>>(),
    );
    expect(bodiesOf(await frank.messages(withFrank)), contains(body));
  });

  test(
    'the old phone reads nothing, not even a conversation it knows',
    () async {
      // Erin is still allowlisted and still a member of both conversations, and
      // her old session still exists in auth.sessions. The only thing that
      // changed is which session is the active one — so this fixture fails that
      // clause of has_app_access() and nothing else.
      expect(bodiesOf(await oldPhone.messages(withFrank)), isEmpty);
      expect(bodiesOf(await oldPhone.messages(withGrace)), isEmpty);
      final listed = await oldPhone.conversations();
      expect((listed as Ok<List<Conversation>>).value, isEmpty);
    },
  );

  test('the old phone cannot send', () async {
    final body = 'from the old phone $stamp';
    expect(
      await oldPhone.send(conversationId: withFrank, body: body),
      isA<Err<Message>>(),
    );
    // Refused, not merely hidden from the sender.
    expect(bodiesOf(await newPhone.messages(withFrank)), isNot(contains(body)));
  });

  test('a Realtime subscription on the old phone stops delivering', () async {
    final body = 'realtime after takeover $stamp';
    final control = frankIncoming
        .firstWhere((m) => m.body == body)
        .timeout(const Duration(seconds: 20));

    expect(
      await newPhone.send(conversationId: withFrank, body: body),
      isA<Ok<Message>>(),
    );
    await control; // the server has fanned this row out to its subscribers
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(
      leakedToOldPhone.map((m) => m.body),
      isEmpty,
      reason: 'an evicted device must not keep receiving over an open socket',
    );
  });

  test(
    'refreshing the old token keeps the same session and no access',
    () async {
      await oldPhoneClient!.auth.refreshSession();
      expect(
        sessionIdOf(oldPhoneClient!),
        oldSessionId,
        reason: 'a refresh must not mint a newer session id',
      );

      expect(
        await oldPhoneClient!.rpc('activate_session'),
        isFalse,
        reason: 'an older session must not be able to take the device back',
      );
      expect(bodiesOf(await oldPhone.messages(withFrank)), isEmpty);
      expect(
        await oldPhone.send(
          conversationId: withFrank,
          body: 'after refresh $stamp',
        ),
        isA<Err<Message>>(),
      );

      // And the attempt must not have knocked the new phone out.
      expect(
        bodiesOf(await newPhone.messages(withFrank)),
        containsAll(historyWithFrank),
      );
    },
  );
}

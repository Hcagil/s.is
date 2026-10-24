@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/video_fakes.dart';

/// A Realtime re-join reaching the open chat, against the real stack (fix
/// "new messages appear at once", t_50655c1325):
/// REAL SupabaseChatRepository(onRejoin:) -> realtimeRejoinedProvider (fed
/// as main.dart feeds it) -> liveCatchUpProvider -> REAL MessagesController.
///
/// The socket is closed under the SDK (its own disconnect() does not mark
/// the channels errored, so nothing would re-join) and sig writes while it is
/// gone; Realtime never delivers that row. When the socket comes back
/// the channel re-joins, onRejoin fires, and the row must appear without any
/// manual catchUp and without the 20 s verify.
///
/// Requires a running local Supabase and the warmup probe. Accounts rho/sig
/// are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
// The suite's shared seed password (supabase/seed.sql).
const _pw = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _pw);
  } on AuthException {
    await client.auth.signUp(email: email, password: _pw);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 15),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (matches(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out after $timeout: $reason');
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

class _Allowed extends SessionController {
  _Allowed(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

void main() {
  SupabaseClient? rhoClient;
  SupabaseClient? sigClient;
  late SupabaseChatRepository sig;
  late String chat;

  setUpAll(() async {
    sigClient = await _signedIn('sig@integration.test');
    rhoClient = await _signedIn('rho@integration.test');
    sig = SupabaseChatRepository(sigClient!);
    await findByTag(rhoClient!, [sigClient!]);
    chat = (await SupabaseChatRepository(rhoClient!).startDirectConversation(
      sigClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
    expect(
      await sig.send(
        id: randomMessageId(),
        conversationId: chat,
        body: _stamp('seed'),
      ),
      isA<Ok<Message>>(),
    );
  });

  tearDownAll(() async {
    await rhoClient?.dispose();
    await sigClient?.dispose();
  });

  Future<void> sigSays(String body) async => expect(
    await sig.send(id: randomMessageId(), conversationId: chat, body: body),
    isA<Ok<Message>>(),
  );

  Future<void> joined() => eventually<List<RealtimeChannel>>(
    () => rhoClient!.getChannels(),
    (cs) => cs.isNotEmpty && cs.every((c) => c.canPush),
    reason: 'the subscription never joined',
  );

  test('a re-join after the socket was gone brings in the missed row on its '
      'own; the first join fires nothing', () async {
    var rejoins = 0;
    final rejoined = StreamController<void>.broadcast();
    addTearDown(rejoined.close);
    final rho = SupabaseChatRepository(
      rhoClient!,
      onRejoin: () {
        rejoins++;
        rejoined.add(null);
      },
    );
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(rho),
        realtimeRejoinedProvider.overrideWithValue(rejoined.stream),
        sessionControllerProvider.overrideWith(
          () => _Allowed(
            Member(userId: rhoClient!.auth.currentUser!.id, displayName: 'Rho'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(liveCatchUpProvider, (_, _) {});
    c.listen(messagesProvider, (_, _) {});
    // The session settles before the chat opens, as after a cold start.
    await c.read(sessionControllerProvider.future);
    c.read(openConversationProvider.notifier).open(chat);
    await c.read(messagesProvider.future);
    await joined();
    List<String> bodies() => [
      for (final m in c.read(messagesProvider).value ?? const <Message>[])
        m.body,
    ];

    final live = _stamp('live');
    await sigSays(live);
    await eventually(bodies, (b) => b.contains(live), reason: 'live first');
    expect(rejoins, 0, reason: 'the first join is not a re-join');

    // The socket drops under the app (as when the OS kills it): the SDK
    // marks the channels errored and reconnects on its own after its backoff.
    await rhoClient!.realtime.conn!.sink.close();
    final gap = _stamp('gap');
    await sigSays(gap);
    expect(
      rhoClient!.realtime.isConnected,
      isFalse,
      reason: 'fixture: the row must be written while the socket is gone',
    );
    await eventually(() => rejoins, (n) => n > 0, reason: 'onRejoin fired');
    await eventually(
      bodies,
      (b) => b.contains(gap),
      reason: 'the re-join must bring the missed row in',
    );
    expect(bodies().where((b) => b == gap).length, 1, reason: 'no duplicate');
    // Once per re-joined messages channel (the open chat's and the list's),
    // never for the error or close statuses on the way down.
    await Future<void>.delayed(const Duration(seconds: 3));
    // rho holds only message channels here (the open chat's and the list's).
    final channels = rhoClient!.getChannels().length;
    expect(channels, greaterThan(0), reason: 'fixture');
    expect(rejoins, channels, reason: 'one per re-joined channel');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

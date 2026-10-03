@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/service_key.dart';

/// 0.30.10 forward page: `MessagesController.forwardTo` over the real
/// repository and database, wired as main.dart wires the chat repository.
///
/// Contract: a person ticked on the forward page who has no chat with the
/// forwarder gets one first (startWith), and the message lands there. If any
/// of those creations fails, forwardTo returns that error and sends nothing
/// at all -- not even to the chats that were ticked and do exist.
///
/// Uses reid, beth and cora (the forward fixtures in supabase/seed.sql);
/// run with --concurrency=1 like the rest of the suite.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    // A fresh stack: the seed allowlists the address, the account is made
    // on first use.
    await client.auth.signUp(email: email, password: _password);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

T _ok<T>(Result<T> r, String what) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => throw TestFailure('$what failed: $failure'),
};

void main() {
  HttpOverrides.global = null;

  late SupabaseClient reidClient, bethClient, coraClient, service;
  late SupabaseChatRepository reid, cora;
  late Member reidMember;
  late String beth, coraId;
  late String c1; // reid+beth: where the forwarded message lives

  String directKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a:$b' : '$b:$a';

  Future<String?> directChat(String a, String b) async {
    final rows = await service
        .from('conversations')
        .select('id')
        .eq('direct_key', directKey(a, b));
    return rows.isEmpty ? null : rows.single['id'] as String;
  }

  setUpAll(() async {
    reidClient = await _signedIn('reid@integration.test');
    bethClient = await _signedIn('beth@integration.test');
    coraClient = await _signedIn('cora@integration.test');
    service = SupabaseClient(_url, serviceKey());
    reid = SupabaseChatRepository(reidClient);
    cora = SupabaseChatRepository(coraClient);
    reidMember = Member(
      userId: reidClient.auth.currentUser!.id,
      displayName: 'Reid',
    );
    beth = bethClient.auth.currentUser!.id;
    coraId = coraClient.auth.currentUser!.id;
    // Reach the way a member gets it: reid found both by exact tag.
    await findByTag(reidClient, [bethClient, coraClient]);
    c1 = _ok(await reid.startDirectConversation(beth), 'reid+beth');
  });

  tearDownAll(() async {
    await reidClient.dispose();
    await bethClient.dispose();
    await coraClient.dispose();
    await service.dispose();
  });

  /// Reid's controllers over the real repository, with c1 open and loaded,
  /// and a fresh message of his in it to forward.
  Future<(ProviderContainer, Message)> reidWithMessage(String body) async {
    final sent = _ok(
      await reid.send(id: randomMessageId(), conversationId: c1, body: body),
      'seeding the message',
    );
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(reid),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(reidMember)),
      ],
    );
    addTearDown(container.dispose);
    await settled(container);
    container.read(openConversationProvider.notifier).open(c1);
    container.listen(messagesProvider, (_, _) {});
    await container.read(messagesProvider.future);
    return (container, sent);
  }

  test('forwarding to a person with no chat creates the chat and delivers '
      'the message there, marked forwarded, readable by that person', () async {
    // No reid+cora chat: the forward page offers cora as a person.
    final old = await directChat(reidMember.userId, coraId);
    if (old != null) await service.from('conversations').delete().eq('id', old);
    expect(await directChat(reidMember.userId, coraId), isNull);

    final body = 'fwd to a person ${DateTime.now().microsecondsSinceEpoch}';
    final (container, message) = await reidWithMessage(body);

    final result = await container
        .read(messagesProvider.notifier)
        .forwardTo(message, conversationIds: const [], personIds: [coraId]);

    expect(result, isA<Ok<void>>(), reason: '$result');
    final created = await directChat(reidMember.userId, coraId);
    expect(created, isNotNull, reason: 'no reid+cora chat was created');

    final there = _ok(await cora.messages(created!), 'cora reading the chat');
    expect(there.map((m) => m.body), [body], reason: 'not delivered there');
    expect(there.single.forwarded, isTrue);
    expect(there.single.senderId, reidMember.userId);
  });

  test('a ticked chat and a new person in one go: both get it', () async {
    final old = await directChat(reidMember.userId, coraId);
    if (old != null) await service.from('conversations').delete().eq('id', old);
    final group = _ok(
      await reid.startGroupConversation(title: 'fwd seam', memberIds: [beth]),
      'a second chat to tick',
    );

    final body = 'fwd to both ${DateTime.now().microsecondsSinceEpoch}';
    final (container, message) = await reidWithMessage(body);
    final result = await container
        .read(messagesProvider.notifier)
        .forwardTo(message, conversationIds: [group], personIds: [coraId]);

    expect(result, isA<Ok<void>>(), reason: '$result');
    final created = await directChat(reidMember.userId, coraId);
    expect(created, isNotNull);
    expect(_ok(await cora.messages(created!), 'new chat').map((m) => m.body), [
      body,
    ]);
    expect(_ok(await reid.messages(group), 'group').map((m) => m.body), [body]);
  });

  test('a chat that cannot be created: forwardTo returns the error and '
      'sends nothing, not even to the ticked chat that exists', () async {
    final c2 = _ok(await reid.startDirectConversation(coraId), 'reid+cora');
    await service.from('messages').delete().eq('conversation_id', c2);

    final body = 'fwd refused ${DateTime.now().microsecondsSinceEpoch}';
    final (container, message) = await reidWithMessage(body);
    // Nobody reid can reach: no such member. The server refuses the chat.
    const stranger = '00000000-0000-4000-8000-00000000f0f0';

    final result = await container
        .read(messagesProvider.notifier)
        .forwardTo(message, conversationIds: [c2], personIds: [stranger]);

    expect(result, isA<Err<void>>(), reason: 'a refused creation passed');
    expect(
      _ok(await reid.messages(c2), 'reading c2'),
      isEmpty,
      reason: 'the existing chat got the message although a creation failed',
    );
    final forwarded = await service
        .from('messages')
        .select('id')
        .eq('sender_id', reidMember.userId)
        .eq('body', body);
    expect(forwarded, hasLength(1), reason: 'only the original may exist');
  });
}

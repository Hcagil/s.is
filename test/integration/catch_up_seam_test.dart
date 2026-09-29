@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';

/// Catching up after the socket died, against the real stack: the REAL
/// ConversationListController and MessagesController on the REAL
/// SupabaseChatRepository, with real Realtime.
///
/// The 0.25.1 defect: while the phone was in the background the OS closed
/// the socket; Realtime delivers nothing published while a subscription is
/// not live, and nothing re-joined or re-read afterwards. Here the socket is
/// closed with the SDK's own disconnect() -- the channels stay as they were,
/// dead -- and sig writes to rho meanwhile. catchUp() must bring the message
/// in and leave a subscription that is live again.
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
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 25),
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

void main() {
  SupabaseClient? rhoClient;
  SupabaseClient? sigClient;
  late SupabaseChatRepository rho;
  late SupabaseChatRepository sig;
  late String chat;

  setUpAll(() async {
    sigClient = await _signedIn('sig@integration.test');
    rhoClient = await _signedIn('rho@integration.test');
    rho = SupabaseChatRepository(rhoClient!);
    sig = SupabaseChatRepository(sigClient!);
    await findByTag(rhoClient!, [sigClient!]);
    chat = (await rho.startDirectConversation(
      sigClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
    expect(
      await rho.send(
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

  /// As production mounts it: only the repository is overridden.
  ProviderContainer container() => ProviderContainer.test(
    overrides: [chatRepositoryProvider.overrideWithValue(rho)],
  );

  Future<void> sigSays(String body) async => expect(
    await sig.send(id: randomMessageId(), conversationId: chat, body: body),
    isA<Ok<Message>>(),
  );

  /// Every Realtime channel rho holds is joined.
  Future<void> joined() => eventually<List<RealtimeChannel>>(
    () => rhoClient!.getChannels(),
    (cs) => cs.isNotEmpty && cs.every((c) => c.canPush),
    reason: 'the subscription never joined',
  );

  /// The phone slept: the socket is gone, the channels stay as they were.
  Future<void> socketDies() async {
    await rhoClient!.realtime.disconnect();
    expect(rhoClient!.realtime.isConnected, isFalse);
  }

  test('the list: a message sent while the socket was dead shows after '
      'catchUp, and the next one arrives live again', () async {
    final c = container();
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    await joined();
    String? preview() => c
        .read(conversationListProvider)
        .value
        ?.where((x) => x.id == chat)
        .firstOrNull
        ?.lastMessage;

    final live = _stamp('live');
    await sigSays(live);
    await eventually(preview, (p) => p == live, reason: 'live before the gap');

    await socketDies();
    final gap = _stamp('gap');
    await sigSays(gap);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(preview(), live, reason: 'the gap must be real');

    await c.read(conversationListProvider.notifier).catchUp();
    await eventually(preview, (p) => p == gap, reason: 'catchUp re-read');

    await joined();
    final after = _stamp('after');
    await sigSays(after);
    await eventually(
      preview,
      (p) => p == after,
      reason: 'catchUp must leave a live subscription',
    );
  });

  test('the open chat: a message sent while the socket was dead shows after '
      'catchUp, and the next one arrives live again', () async {
    final c = container();
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(chat);
    await c.read(messagesProvider.future);
    await joined();
    List<String> bodies() => [
      for (final m in c.read(messagesProvider).value ?? const <Message>[])
        m.body,
    ];

    final live = _stamp('live-m');
    await sigSays(live);
    await eventually(bodies, (b) => b.contains(live), reason: 'live first');

    await socketDies();
    final gap = _stamp('gap-m');
    await sigSays(gap);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(bodies(), isNot(contains(gap)), reason: 'the gap must be real');

    c.read(messagesProvider.notifier).catchUp();
    await eventually(bodies, (b) => b.contains(gap), reason: 'catchUp read');

    await joined();
    final after = _stamp('after-m');
    await sigSays(after);
    await eventually(
      bodies,
      (b) => b.contains(after),
      reason: 'catchUp must leave a live subscription',
    );
  });
}

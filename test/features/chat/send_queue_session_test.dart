// Sends in the unconfirmed window of a cold start (0.30.15): a message typed
// while the session is still Allowed(confirmed: false) is queued and sent as
// usual -- RLS on messages decides -- but a Denied answer drops every queued
// send for good, and a refused insert (42501, non-retryable) is never
// retried. The real SessionController runs over the cold-start fakes.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/held_send_chat.dart';
import '../../support/last_session_fakes.dart';
import '../../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const offline = NetworkFailure('No connection', retryable: true);
const refused = NetworkFailure(
  'new row violates row-level security policy for table "messages"',
);

Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(Duration.zero);
  }
}

late ProviderContainer c;

Future<(ColdAuth, HeldSendChat)> start(WidgetTester t) async {
  final auth = ColdAuth();
  final chat = HeldSendChat();
  c = ProviderContainer(
    overrides: [
      ...videoOverrides(),
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(auth),
      lastSessionStoreProvider.overrideWithValue(
        MemoryLastSessionStore(marker()),
      ),
      chatRepositoryProvider.overrideWithValue(chat),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  await hop(t);
  final s = c.read(sessionControllerProvider).value;
  expect(s, isA<Allowed>().having((a) => a.confirmed, 'confirmed', false));
  return (auth, chat);
}

List<Message> queued(String conv) =>
    c.read(sendQueueProvider)[conv] ?? const [];

Future<void> end(WidgetTester t) async {
  c.dispose();
  await hop(t);
}

void main() {
  testWidgets('a send while unconfirmed is queued and sent', (t) async {
    final (_, chat) = await start(t);
    c.read(sendQueueProvider.notifier).enqueue('c1', body: 'hi');
    await hop(t);
    expect(chat.asked, hasLength(1), reason: 'the send waited for the check');
    expect(queued('c1'), hasLength(1));
    await end(t);
  });

  testWidgets('Denied drops the queue; the in-flight send failing afterwards '
      'is never retried', (t) async {
    final (auth, chat) = await start(t);
    final q = c.read(sendQueueProvider.notifier);
    q.enqueue('c1', body: 'one');
    q.enqueue('c1', body: 'two');
    q.enqueue('c2', body: 'three');
    await hop(t);
    expect(chat.asked, isNotEmpty);
    final askedBefore = chat.asked.length;

    auth.last.deny();
    await hop(t);
    expect(c.read(sessionControllerProvider).value, isA<Denied>());
    expect(queued('c1'), isEmpty, reason: 'a revoked member kept a queue');
    expect(queued('c2'), isEmpty);

    for (var i = 0; i < chat.asked.length; i++) {
      if (!chat.asked[i].answer.isCompleted) chat.fail(i, offline);
    }
    await hop(t);
    await t.pump(const Duration(seconds: 30));
    await hop(t);
    expect(
      chat.asked,
      hasLength(askedBefore),
      reason: 'a dropped send retried',
    );
    expect(queued('c1'), isEmpty);
    await end(t);
  });

  testWidgets('an insert refused by RLS (42501) is not retried', (t) async {
    final (_, chat) = await start(t);
    c.read(sendQueueProvider.notifier).enqueue('c1', body: 'hi');
    await hop(t);
    chat.fail(0, refused);
    await hop(t);
    await t.pump(const Duration(seconds: 30));
    await hop(t);
    expect(chat.asked, hasLength(1), reason: 'a refused insert was retried');
    await end(t);
  });

  testWidgets('control: an offline failure while unconfirmed is retried', (
    t,
  ) async {
    final (_, chat) = await start(t);
    c.read(sendQueueProvider.notifier).enqueue('c1', body: 'hi');
    await hop(t);
    chat.fail(0, offline);
    await hop(t);
    await t.pump(const Duration(seconds: 30));
    await hop(t);
    expect(chat.asked.length, greaterThan(1));
    await end(t);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/file_fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

const offline = NetworkFailure('No connection', retryable: true);

Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump();
  }
}

Future<ProviderContainer> start(
  WidgetTester t,
  HeldSendChat chat,
  FileRepoFake files,
) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      chatFileRepositoryProvider.overrideWithValue(files),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  await hop(t);
  await t.pump(const Duration(milliseconds: 1));
  expect(c.read(sessionControllerProvider).value, isA<Allowed>());
  return c;
}

void main() {
  testWidgets('enqueueFile returns pending message immediately', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final c = await start(t, chat, files);
    final controller = c.read(sendQueueProvider.notifier);

    final pending = controller.enqueueFile('c1', picked('f1'));
    expect(pending.id, 'f1');
    expect(pending.sending, true);
    expect(pending.file, isNotNull);
    expect(pending.file!.name, 'Cabin booking.pdf');
    expect(pending.file!.mime, 'application/pdf');
    expect(pending.file!.size, 2516582);

    // Queue state
    expect(c.read(sendQueueProvider)['c1']?.first, pending);

    await hop(t);
    // After hop, one send asked
    expect(files.sends.length, 1);
    expect(files.sends[0].conversationId, 'c1');
    expect(files.sends[0].file.id, 'f1');

    // Answer the send
    files.sendOk(0);
    await hop(t);
    // Queue should be empty
    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);

    // Drain remaining timers
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('offline retry backoff', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final c = await start(t, chat, files);
    final controller = c.read(sendQueueProvider.notifier);

    controller.enqueueFile('c1', picked('f1'));
    await hop(t);
    // First attempt
    expect(files.sends.length, 1);
    expect(files.sends[0].file.id, 'f1');
    files.sendFail(0, offline);

    final backoffs = [1, 2, 4, 5, 5];
    int askIndex = 1;
    for (final seconds in backoffs) {
      // Wait until just before the next retry
      await t.pump(
        Duration(seconds: seconds) - const Duration(milliseconds: 1),
      );
      await hop(t);
      expect(files.sends.length, askIndex); // no new send yet
      final waiting = c.read(sendQueueProvider)['c1']!;
      expect(waiting.single.id, 'f1', reason: 'still queued');
      expect(waiting.single.sending, isTrue, reason: 'the clock shows');

      // Advance to the retry moment
      await t.pump(const Duration(milliseconds: 1));
      await hop(t);
      expect(files.sends.length, askIndex + 1);
      expect(files.sends[askIndex].file.id, 'f1');
      files.sendFail(askIndex, offline);
      askIndex++;
    }

    // Final successful send
    await t.pump(const Duration(seconds: 5));
    await hop(t);
    expect(files.sends.length, askIndex + 1);
    files.sendOk(askIndex);
    await hop(t);
    // Queue should be empty
    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);

    // No further retries after 30s
    await t.pump(const Duration(seconds: 30));
    await hop(t);
    expect(files.sends.length, askIndex + 1);

    // Drain remaining timers
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('replyTo is set correctly', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final c = await start(t, chat, files);
    final controller = c.read(sendQueueProvider.notifier);

    final replyMsg = Message(
      id: 'm9',
      conversationId: 'c1',
      senderId: 'u2',
      body: 'q',
      createdAt: DateTime.now(),
    );

    controller.enqueueFile('c1', picked('f2'), replyTo: replyMsg);
    await hop(t);
    expect(files.sends.length, 1);
    expect(files.sends[0].replyTo, 'm9');

    files.sendOk(0);
    await hop(t);
    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);

    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('file and text order preserved', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final c = await start(t, chat, files);
    final controller = c.read(sendQueueProvider.notifier);

    controller.enqueueFile('c1', picked('f1'));
    controller.enqueue('c1', body: 'after');
    await hop(t);

    // File should be sent first
    expect(files.sends.length, 1);
    expect(files.sends[0].file.id, 'f1');
    expect(chat.asked.isEmpty, true);

    files.sendOk(0);
    await hop(t);

    // Text should now be sent
    expect(chat.asked.length, 1);
    expect(chat.asked[0].body, 'after');

    chat.ok(0);
    await hop(t);

    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('non-retryable failure stops retrying', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final c = await start(t, chat, files);
    final controller = c.read(sendQueueProvider.notifier);

    controller.enqueueFile('c1', picked('f3'));
    await hop(t);
    expect(files.sends.length, 1);
    files.sendFail(0, NetworkFailure('refused', retryable: false));

    // Wait 30 seconds to ensure no retry
    await t.pump(const Duration(seconds: 30));
    await hop(t);
    expect(files.sends.length, 1); // still only the first attempt

    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/video.dart';

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
  WidgetTester t, {
  required HeldSendChat chat,
  required FileRepoFake files,
  required DeviceVideosFake videos,
  required SendQueueStoreFake store,
}) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(store: store, videos: videos),
      chatRepositoryProvider.overrideWithValue(chat),
      chatFileRepositoryProvider.overrideWithValue(files),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  c.listen(videoProgressProvider, (_, _) {});
  await hop(t);
  await t.pump(const Duration(milliseconds: 1));
  return c;
}

void main() {
  testWidgets('1. enqueueVideo returns pending message and is queued', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    final msg = c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);

    expect(msg.id, 'v1');
    expect(msg.sending, true);
    final file = msg.file!;
    expect(file.isVideo, true);
    expect(file.name, videoFileName(video.name));
    expect(file.mime, videoMime);
    expect(file.durationMs, video.durationMs);

    final queue = c.read(sendQueueProvider)['c1']!;
    expect(queue.length, 1);
    expect(queue.first.id, 'v1');

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('2. full drain of a video send', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);

    expect(videos.compressions.length, 1);
    expect(videos.compressions.first.source.id, 'v1');
    expect(files.sends.isEmpty, true);
    expect(c.read(videoProgressProvider)['v1']!.stage, VideoStage.compressing);

    videos.progress(0, 0.5);
    await hop(t);
    expect(c.read(videoProgressProvider)['v1']!.fraction, 0.5);
    expect(c.read(videoProgressProvider)['v1']!.stage, VideoStage.compressing);

    videos.compressOk(0);
    await hop(t);
    expect(files.sends.length, 1);
    expect(files.sends.first.file.id, 'v1');
    expect(files.sends.first.file.mime, videoMime);
    expect(files.sends.first.file.durationMs, video.durationMs);
    expect(c.read(videoProgressProvider)['v1']!.stage, VideoStage.sending);

    files.sendProgress(0, 0.25);
    await hop(t);
    expect(c.read(videoProgressProvider)['v1']!.fraction, 0.25);
    expect(c.read(videoProgressProvider)['v1']!.stage, VideoStage.sending);

    files.sendOk(0);
    await hop(t);
    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
    expect(c.read(videoProgressProvider)['v1'], isNull);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('3. cancelVideo while shrinking', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);

    final cancelled = c
        .read(sendQueueProvider.notifier)
        .cancelVideo('c1', 'v1');
    expect(cancelled, true);

    await hop(t);
    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
    expect(files.sends.isEmpty, true);
    expect(videos.cancels, 1, reason: 'the running shrink is stopped');
    expect(videos.discarded, contains('v1'), reason: 'the picked copy goes');

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('4. cancelVideo while uploading', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);
    videos.compressOk(0);
    await hop(t);

    final cancelled = c
        .read(sendQueueProvider.notifier)
        .cancelVideo('c1', 'v1');
    expect(cancelled, false);

    await hop(t);
    expect(c.read(sendQueueProvider)['c1']!.length, 1);
    expect(files.sends.length, 1);

    files.sendOk(0);
    await hop(t);
    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('5. compress fails with VideoTooBigFailure', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);

    videos.compressFail(0, VideoTooBigFailure());
    await hop(t);

    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
    expect(c.read(draftsProvider)['c1']?.failure, isA<VideoTooBigFailure>());
    expect(videos.discarded, contains('v1'));
    expect(files.sends.isEmpty, true);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('6. compress fails with VideoFailedFailure', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);

    videos.compressFail(0, VideoFailedFailure());
    await hop(t);

    expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
    expect(c.read(draftsProvider)['c1']?.failure, isA<VideoFailedFailure>());
    expect(videos.discarded, contains('v1'));
    expect(files.sends.isEmpty, true);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('7. upload fails retryable (offline)', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);
    videos.compressOk(0);
    await hop(t);

    files.sendFail(0, offline);
    await hop(t);

    expect(c.read(videoProgressProvider)['v1']!.stage, VideoStage.waiting);

    await t.pump(const Duration(seconds: 6));
    await hop(t);

    expect(files.sends.length, 2);
    expect(videos.compressions.length, 1);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('8. two videos queued, only first shrinks', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final v1 = videoSource('v1');
    final v2 = videoSource('v2');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', v1);
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', v2);
    await hop(t);

    expect(videos.compressions.length, 1);
    expect(videos.compressions.first.source.id, 'v1');
    expect(c.read(videoProgressProvider)['v1'] != null, true);
    expect(c.read(videoProgressProvider)['v2'], isNull);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('9. replyTo video send', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final reply = Message(
      id: 'm9',
      conversationId: 'c1',
      senderId: 'u2',
      body: 'hi',
      createdAt: DateTime(2026),
    );
    final video = videoSource('v1');
    c
        .read(sendQueueProvider.notifier)
        .enqueueVideo('c1', video, replyTo: reply);
    await hop(t);
    videos.compressOk(0);
    await hop(t);
    files.sendOk(0);
    await hop(t);

    expect(files.sends.first.replyTo, 'm9');

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('10. persistence of queued video', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final c = await start(
      t,
      chat: chat,
      files: files,
      videos: videos,
      store: store,
    );

    final video = videoSource('v1');
    c.read(sendQueueProvider.notifier).enqueueVideo('c1', video);
    await hop(t);

    final records = store.records('u1');
    expect(records.length, 1);
    expect(records.first.id, 'v1');
    expect(records.first.video?.id, 'v1');

    videos.compressOk(0);
    await hop(t);
    files.sendOk(0);
    await hop(t);

    expect(store.saved.containsKey('u1'), false);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });

  testWidgets('11. KILL/RESTORE restores queue and resumes sends', (
    WidgetTester t,
  ) async {
    // Container A
    final chatA = HeldSendChat();
    final filesA = FileRepoFake();
    final videosA = DeviceVideosFake();
    final store = SendQueueStoreFake();
    final cA = await start(
      t,
      chat: chatA,
      files: filesA,
      videos: videosA,
      store: store,
    );

    final textMsg = cA
        .read(sendQueueProvider.notifier)
        .enqueue('c1', body: 'hello');
    final fileMsg = cA
        .read(sendQueueProvider.notifier)
        .enqueueFile('c1', picked('f1'));
    final videoMsg = cA
        .read(sendQueueProvider.notifier)
        .enqueueVideo('c1', videoSource('v1'));
    await hop(t);
    cA.dispose();

    // Container B
    final chatB = HeldSendChat();
    final filesB = FileRepoFake();
    final videosB = DeviceVideosFake();
    final cB = ProviderContainer.test(
      overrides: [
        ...videoOverrides(store: store, videos: videosB),
        chatRepositoryProvider.overrideWithValue(chatB),
        chatFileRepositoryProvider.overrideWithValue(filesB),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    );
    cB.listen(sessionControllerProvider, (_, _) {});
    cB.listen(sendQueueProvider, (_, _) {});
    cB.listen(videoProgressProvider, (_, _) {});
    await hop(t);
    await t.pump(const Duration(milliseconds: 1));

    final queue = cB.read(sendQueueProvider)['c1']!;
    expect(queue.map((m) => m.id).toList(), [
      textMsg.id,
      fileMsg.id,
      videoMsg.id,
    ]);

    // Text resend
    expect(chatB.asked.single.body, 'hello');
    expect(chatB.asked.single.id, textMsg.id);
    chatB.ok(0);
    await hop(t);

    // File upload
    expect(filesB.sends.first.file.id, 'f1');
    filesB.sendOk(0);
    await hop(t);

    // Video shrink
    expect(videosB.compressions.first.source.id, 'v1');
    videosB.compressOk(0);
    await hop(t);

    // Video upload
    expect(filesB.sends.last.file.id, 'v1');
    filesB.sendOk(1);
    await hop(t);

    expect(cB.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);

    await t.pump(const Duration(seconds: 30));
    await hop(t);
  });
}

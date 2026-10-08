import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/video.dart';

import '../../support/file_fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_chat.dart';
import '../../support/video_fakes.dart';

void main() {
  group('Video chat UI', () {
    testWidgets('1. Received video shows bubble and duration', (
      WidgetTester t,
    ) async {
      final chat = world()
        ..messagesResult = Ok([
          fileMessage(
            'v1',
            name: 'Beach day.mp4',
            mime: videoMime,
            size: 8388608,
            durationMs: 41000,
          ),
        ]);
      await pumpVideoChat(t, chat);
      await frames(t);
      expect(find.byKey(const Key('video-v1')), findsOneWidget);
      expect(find.text('0:41'), findsOneWidget);
    });

    testWidgets('2. Mobile default: no download asked', (WidgetTester t) async {
      final d = DeviceFilesFake();
      final repo = FileRepoFake(devices: d);
      final chat = world()
        ..messagesResult = Ok([
          fileMessage(
            'v1',
            name: 'Beach day.mp4',
            mime: videoMime,
            size: 8388608,
            durationMs: 41000,
          ),
        ]);
      await pumpVideoChat(t, chat, repo: repo, devices: d);
      await frames(t);
      expect(repo.downloads.isEmpty, isTrue);
    });

    testWidgets(
      '3. Wifi default: auto‑download requested and ring disappears',
      (WidgetTester t) async {
        final d = DeviceFilesFake();
        final repo = FileRepoFake(devices: d);
        final chat = world()
          ..messagesResult = Ok([
            fileMessage(
              'v1',
              name: 'Beach day.mp4',
              mime: videoMime,
              size: 8388608,
              durationMs: 41000,
            ),
          ]);
        await pumpVideoChat(
          t,
          chat,
          repo: repo,
          devices: d,
          probe: ProbeFake(NetworkKind.wifi),
        );
        await frames(t);
        expect(
          repo.downloads.map((d) => d.attachmentPath),
          contains('c1/v1/Beach day.mp4'),
        );
        expect(find.byKey(const Key('video-ring-v1')), findsOneWidget);
        repo.downloadOk(0);
        await frames(t);
        expect(find.byKey(const Key('video-ring-v1')), findsNothing);
      },
    );

    for (final (kinds, downloads) in [
      ({MediaKind.videos}, true),
      ({MediaKind.documents}, false),
    ]) {
      testWidgets(
        '4. Mobile with rules $kinds: downloads by itself: $downloads',
        (WidgetTester t) async {
          final d = DeviceFilesFake();
          final repo = FileRepoFake(devices: d);
          final chat = world()
            ..messagesResult = Ok([
              fileMessage(
                'v1',
                name: 'Beach day.mp4',
                mime: videoMime,
                size: 8388608,
                durationMs: 41000,
              ),
            ]);
          await pumpVideoChat(
            t,
            chat,
            repo: repo,
            devices: d,
            probe: ProbeFake(NetworkKind.mobile),
            settings: AutoDownloadSettings(rules: {NetworkKind.mobile: kinds}),
          );
          await frames(t);
          expect(repo.downloads.isNotEmpty, downloads);
        },
      );
    }

    testWidgets('5. After download, play opens player and can be closed', (
      WidgetTester t,
    ) async {
      final d = DeviceFilesFake();
      final repo = FileRepoFake(devices: d);
      final playback = VideoPlaybackFactoryFake();
      final chat = world()
        ..messagesResult = Ok([
          fileMessage(
            'v1',
            name: 'Beach day.mp4',
            mime: videoMime,
            size: 8388608,
            durationMs: 41000,
          ),
        ]);
      await pumpVideoChat(
        t,
        chat,
        repo: repo,
        devices: d,
        probe: ProbeFake(NetworkKind.wifi),
        playback: playback,
      );
      await frames(t);
      repo.downloadOk(0);
      await frames(t);
      await t.tap(find.byKey(const Key('video-play-v1')));
      await frames(t);
      expect(playback.made.length, 1);
      expect(
        playback.made.single.openedPath!.endsWith('Beach day.mp4'),
        isTrue,
      );
      expect(find.byKey(const Key('video-close')), findsOneWidget);
      await t.tap(find.byKey(const Key('video-close')));
      await frames(t);
      expect(find.byKey(const Key('video-close')), findsNothing);
    });

    testWidgets('6. Own pending video: compressing → sending', (
      WidgetTester t,
    ) async {
      final repo = FileRepoFake(devices: DeviceFilesFake());
      final videos = DeviceVideosFake();
      final chat = world();
      final container = await pumpVideoChat(
        t,
        chat,
        repo: repo,
        videos: videos,
      );
      await frames(t);

      // Enqueue video
      container
          .read(sendQueueProvider.notifier)
          .enqueueVideo('c1', videoSource('v1'));
      await frames(t);

      // Compressing 0%
      expect(find.byKey(const Key('video-v1')), findsOneWidget);
      expect(find.text(l10nEn.videoCompressing(0)), findsOneWidget);
      expect(find.byKey(const Key('video-cancel-v1')), findsOneWidget);

      // Compressing progress
      videos.progress(0, 0.42);
      await frames(t);
      expect(find.text(l10nEn.videoCompressing(42)), findsOneWidget);

      // Compression finished
      videos.compressOk(0);
      await frames(t);
      expect(find.text(l10nEn.videoSending(0)), findsOneWidget);
      expect(find.byKey(const Key('video-cancel-v1')), findsNothing);

      // Sending progress
      repo.sendProgress(0, 0.5);
      await frames(t);
      expect(find.text(l10nEn.videoSending(50)), findsOneWidget);
    });

    testWidgets(
      '7. Cancel while compressing removes bubble and aborts upload',
      (WidgetTester t) async {
        final repo = FileRepoFake(devices: DeviceFilesFake());
        final videos = DeviceVideosFake();
        final chat = world();
        final container = await pumpVideoChat(
          t,
          chat,
          repo: repo,
          videos: videos,
        );
        await frames(t);

        container
            .read(sendQueueProvider.notifier)
            .enqueueVideo('c1', videoSource('v1'));
        await frames(t);

        await t.tap(find.byKey(const Key('video-cancel-v1')));
        await frames(t);

        expect(find.byKey(const Key('video-v1')), findsNothing);
        expect(repo.sends.isEmpty, isTrue);
      },
    );

    testWidgets('8. Upload fails retryable → waiting network', (
      WidgetTester t,
    ) async {
      final repo = FileRepoFake(devices: DeviceFilesFake());
      final videos = DeviceVideosFake();
      final chat = world();
      final container = await pumpVideoChat(
        t,
        chat,
        repo: repo,
        videos: videos,
      );
      await frames(t);

      container
          .read(sendQueueProvider.notifier)
          .enqueueVideo('c1', videoSource('v1'));
      await frames(t);
      videos.compressOk(0);
      await frames(t);

      repo.sendFail(0, NetworkFailure('No connection', retryable: true));
      // The first retry comes after 1 s; look before it.
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }

      final shown = t
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('video-v1')),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.data)
          .toList();
      expect(
        find.text(l10nEn.videoWaitingNetwork),
        findsOneWidget,
        reason: '$shown',
      );
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('9. Compression fails → show error notice', (
      WidgetTester t,
    ) async {
      final repo = FileRepoFake(devices: DeviceFilesFake());
      final videos = DeviceVideosFake();
      final chat = world();
      final container = await pumpVideoChat(
        t,
        chat,
        repo: repo,
        videos: videos,
      );
      await frames(t);

      container
          .read(sendQueueProvider.notifier)
          .enqueueVideo('c1', videoSource('v1'));
      await frames(t);
      videos.compressFail(0, VideoTooBigFailure());
      await frames(t);
      expect(find.text(l10nEn.videoTooBig), findsOneWidget);
      expect(find.byKey(const Key('video-v1')), findsNothing);

      // Retry with generic failure
      container
          .read(sendQueueProvider.notifier)
          .enqueueVideo('c1', videoSource('v2'));
      await frames(t);
      videos.compressFail(1, VideoFailedFailure());
      await frames(t);
      expect(find.text(l10nEn.videoFailed), findsOneWidget);
      expect(find.byKey(const Key('video-v2')), findsNothing);
      await noticeGone(t);
    });

    testWidgets('10. Composer flow: pick, review, send', (
      WidgetTester t,
    ) async {
      final videos = DeviceVideosFake(
        pickResult: VideoPick(videos: [videoSource('a'), videoSource('b')]),
      );
      final chat = world();
      await pumpVideoChat(t, chat, videos: videos);
      await frames(t);

      await t.tap(find.byKey(const Key('composer-attach')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-video')));
      await frames(t);

      expect(find.text(l10nEn.videoReviewTitle), findsOneWidget);
      expect(find.byKey(const Key('video-tile-a')), findsOneWidget);
      expect(find.byKey(const Key('video-tile-b')), findsOneWidget);
      expect(find.text(l10nEn.videoSendCount(2)), findsOneWidget);

      await t.tap(find.byKey(const Key('video-tile-b')));
      await frames(t);
      expect(find.text(l10nEn.videoSendCount(1)), findsOneWidget);

      await t.tap(find.byKey(const Key('video-send')));
      await frames(t);

      expect(find.byKey(const Key('video-a')), findsOneWidget);
      expect(find.byKey(const Key('video-b')), findsNothing);
      expect(videos.discarded, contains('b'));
    });

    testWidgets('11. Review page: deselect all disables send', (
      WidgetTester t,
    ) async {
      final videos = DeviceVideosFake(
        pickResult: VideoPick(videos: [videoSource('a'), videoSource('b')]),
      );
      final chat = world();
      await pumpVideoChat(t, chat, videos: videos);
      await frames(t);

      await t.tap(find.byKey(const Key('composer-attach')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-video')));
      await frames(t);

      // Deselect both
      await t.tap(find.byKey(const Key('video-tile-a')));
      await frames(t);
      await t.tap(find.byKey(const Key('video-tile-b')));
      await frames(t);

      // Send button disabled; tapping does nothing
      await t.tap(find.byKey(const Key('video-send')));
      await frames(t);

      expect(find.text(l10nEn.videoReviewTitle), findsOneWidget);
      expect(find.byKey(const Key('video-a')), findsNothing);
      expect(find.byKey(const Key('video-b')), findsNothing);
    });

    testWidgets('12. Picking with tooLong shows notice and review page', (
      WidgetTester t,
    ) async {
      final videos = DeviceVideosFake(
        pickResult: VideoPick(videos: [videoSource('a')], tooLong: 1),
      );
      final chat = world();
      await pumpVideoChat(t, chat, videos: videos);
      await frames(t);
      await t.tap(find.byKey(const Key('composer-attach')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-video')));
      await frames(t);

      expect(find.text(l10nEn.videoTooLong(1)), findsOneWidget);
      expect(find.text(l10nEn.videoReviewTitle), findsOneWidget);
      await noticeGone(t);
    });

    testWidgets('13. Picking with no videos shows no review page', (
      WidgetTester t,
    ) async {
      final videos = DeviceVideosFake(pickResult: VideoPick());
      final chat = world();
      await pumpVideoChat(t, chat, videos: videos);
      await frames(t);
      await t.tap(find.byKey(const Key('composer-attach')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-video')));
      await frames(t);
      expect(videos.picks, 1);

      expect(find.text(l10nEn.videoReviewTitle), findsNothing);
    });

    testWidgets('14. Turkish locale: first label is Turkish', (
      WidgetTester t,
    ) async {
      final repo = FileRepoFake(devices: DeviceFilesFake());
      final videos = DeviceVideosFake();
      final chat = world();
      final container = await pumpVideoChat(
        t,
        chat,
        repo: repo,
        videos: videos,
        locale: const Locale('tr'),
      );
      await frames(t);

      container
          .read(sendQueueProvider.notifier)
          .enqueueVideo('c1', videoSource('v1'));
      await frames(t);

      expect(find.text(l10nTr.videoCompressing(0)), findsOneWidget);
    });
  });
}

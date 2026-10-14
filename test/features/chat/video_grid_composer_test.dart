import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/video.dart';

import '../../support/l10n.dart';
import '../../support/video_chat.dart';
import '../../support/video_fakes.dart';
import '../../support/video_gallery_fakes.dart';

void main() {
  group('VideoGridComposer', () {
    testWidgets('grid enabled, pick through the grid', (WidgetTester t) async {
      final videos = DeviceVideosFake();
      final g = VideoGalleryFake(videos: galleryVideos(3));

      await pumpVideoChat(
        t,
        world(),
        videos: videos,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(true),
        ],
      );
      await frames(t);

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);
      await t.tap(byKey('video-grid-v0'));
      await frames(t);
      await t.tap(byKey('video-send'));
      await frames(t);

      g.prepares.single.answer.complete(
        VideoPick(videos: [videoSource('a'), videoSource('b')]),
      );
      await frames(t);

      expect(find.byKey(Key('video-a')), findsOneWidget);
      expect(find.byKey(Key('video-b')), findsOneWidget);
      expect(find.byKey(Key('video-tile-a')), findsNothing);
      expect(videos.picks, 0);
      expect(videos.discarded, isEmpty);
    });

    testWidgets('grid enabled, back out of the grid', (WidgetTester t) async {
      final videos = DeviceVideosFake();
      final g = VideoGalleryFake(videos: galleryVideos(3));

      await pumpVideoChat(
        t,
        world(),
        videos: videos,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(true),
        ],
      );
      await frames(t);

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);
      await t.tap(byKey('video-grid-v0'));
      await frames(t);

      await t.binding.handlePopRoute();
      await frames(t);

      expect(find.byKey(Key('video-a')), findsNothing);
      expect(videos.picks, 0);
      expect(find.byKey(Key('video-send')), findsNothing);
    });

    testWidgets(
      'grid enabled, grid answers VideoPick(videos:[videoSource(\'a\')], tooLong: 2)',
      (WidgetTester t) async {
        final videos = DeviceVideosFake();
        final g = VideoGalleryFake(videos: galleryVideos(3));

        await pumpVideoChat(
          t,
          world(),
          videos: videos,
          extra: [
            videoGalleryProvider.overrideWithValue(g),
            videoGridEnabledProvider.overrideWithValue(true),
          ],
        );
        await frames(t);

        await t.tap(byKey('composer-attach'));
        await frames(t);
        await t.tap(byKey('attach-video'));
        await frames(t);
        await t.tap(byKey('video-grid-v0'));
        await frames(t);
        await t.tap(byKey('video-send'));
        await frames(t);

        g.prepares.single.answer.complete(
          VideoPick(videos: [videoSource('a')], tooLong: 2),
        );
        await frames(t);

        expect(find.text(l10nEn.videoTooLong(2)), findsOneWidget);
        expect(find.byKey(Key('video-a')), findsOneWidget);
        await noticeGone(t);
      },
    );

    testWidgets(
      'grid enabled, grid answers VideoPick(tooLong: 1) (no videos)',
      (WidgetTester t) async {
        final videos = DeviceVideosFake();
        final g = VideoGalleryFake(videos: galleryVideos(3));

        await pumpVideoChat(
          t,
          world(),
          videos: videos,
          extra: [
            videoGalleryProvider.overrideWithValue(g),
            videoGridEnabledProvider.overrideWithValue(true),
          ],
        );
        await frames(t);

        await t.tap(byKey('composer-attach'));
        await frames(t);
        await t.tap(byKey('attach-video'));
        await frames(t);
        await t.tap(byKey('video-grid-v0'));
        await frames(t);
        await t.tap(byKey('video-send'));
        await frames(t);

        g.prepares.single.answer.complete(VideoPick(tooLong: 1));
        await frames(t);

        expect(find.text(l10nEn.videoTooLong(1)), findsOneWidget);
        expect(find.byKey(Key('video-send')), findsNothing);
        expect(find.byKey(Key('video-tile-a')), findsNothing);
        await noticeGone(t);
      },
    );

    testWidgets(
      'grid enabled, access denied (VideoGalleryFake(access: GalleryAccess.denied))',
      (WidgetTester t) async {
        final g = VideoGalleryFake(
          access: GalleryAccess.denied,
          videos: galleryVideos(3),
        );
        final videos = DeviceVideosFake(
          pickResult: VideoPick(videos: [videoSource('a')]),
        );

        await pumpVideoChat(
          t,
          world(),
          videos: videos,
          extra: [
            videoGalleryProvider.overrideWithValue(g),
            videoGridEnabledProvider.overrideWithValue(true),
          ],
        );
        await frames(t);

        await t.tap(byKey('composer-attach'));
        await frames(t);
        await t.tap(byKey('attach-video'));
        await frames(t);
        await t.tap(byKey('video-phone-picker'));
        await frames(t);

        expect(videos.picks, 1);
        expect(find.byKey(Key('video-tile-a')), findsOneWidget);

        await t.tap(byKey('video-send'));
        await frames(t);

        expect(find.byKey(Key('video-a')), findsOneWidget);
      },
    );

    testWidgets('grid enabled, denied, tap video-not-now', (
      WidgetTester t,
    ) async {
      final g = VideoGalleryFake(
        access: GalleryAccess.denied,
        videos: galleryVideos(3),
      );
      final videos = DeviceVideosFake();

      await pumpVideoChat(
        t,
        world(),
        videos: videos,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(true),
        ],
      );
      await frames(t);

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);
      await t.tap(byKey('video-not-now'));
      await frames(t);

      expect(videos.picks, 0);
      expect(find.byKey(Key('video-a')), findsNothing);
    });

    testWidgets('grid disabled, still pass gallery override', (
      WidgetTester t,
    ) async {
      final g = VideoGalleryFake(videos: galleryVideos(3));
      final videos = DeviceVideosFake(
        pickResult: VideoPick(videos: [videoSource('a')]),
      );

      await pumpVideoChat(
        t,
        world(),
        videos: videos,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(false),
        ],
      );
      await frames(t);

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);

      expect(videos.picks, 1);
      expect(find.byKey(Key('video-tile-a')), findsOneWidget);
      expect(g.accessRequests, 0);
      expect(find.byKey(Key('video-grid-v0')), findsNothing);
    });

    testWidgets('grid disabled, pickResult VideoPick(tooLong: 1)', (
      WidgetTester t,
    ) async {
      final g = VideoGalleryFake(videos: galleryVideos(3));
      final videos = DeviceVideosFake(pickResult: VideoPick(tooLong: 1));

      await pumpVideoChat(
        t,
        world(),
        videos: videos,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(false),
        ],
      );
      await frames(t);

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);

      expect(find.text(l10nEn.videoTooLong(1)), findsOneWidget);
      expect(find.byKey(Key('video-tile-a')), findsNothing);
      await noticeGone(t);
    });

    testWidgets(
      'Turkish locale, grid enabled, answer VideoPick(videos:[videoSource(\'a\')], tooLong: 1)',
      (WidgetTester t) async {
        final videos = DeviceVideosFake();
        final g = VideoGalleryFake(videos: galleryVideos(3));

        await pumpVideoChat(
          t,
          world(),
          videos: videos,
          locale: const Locale('tr'),
          extra: [
            videoGalleryProvider.overrideWithValue(g),
            videoGridEnabledProvider.overrideWithValue(true),
          ],
        );
        await frames(t);

        await t.tap(byKey('composer-attach'));
        await frames(t);
        await t.tap(byKey('attach-video'));
        await frames(t);
        await t.tap(byKey('video-grid-v0'));
        await frames(t);
        await t.tap(byKey('video-send'));
        await frames(t);

        g.prepares.single.answer.complete(
          VideoPick(videos: [videoSource('a')], tooLong: 1),
        );
        await frames(t);

        expect(find.text(l10nTr.videoTooLong(1)), findsOneWidget);
        expect(find.byKey(Key('video-a')), findsOneWidget);
        await noticeGone(t);
      },
    );
  });

  group('chat screen gone', () {
    testWidgets('grid enabled, close after send', (WidgetTester t) async {
      final g = VideoGalleryFake(videos: galleryVideos(3));
      final videos = DeviceVideosFake();

      final container = await pumpVideoChat(
        t,
        world(),
        videos: videos,
        asRoute: true,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(true),
        ],
      );

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);

      await t.tap(byKey('video-grid-v0'));
      await frames(t);
      await t.tap(byKey('video-send'));
      await frames(t);

      await closeChat(t);

      // The grid's send completes after the chat screen is gone.
      g.prepares.single.answer.complete(
        VideoPick(videos: [videoSource('a'), videoSource('b')]),
      );
      await frames(t);

      expect(videos.discarded, unorderedEquals(['a', 'b']));
      expect(videos.picks, 0);
      expect(
        container.read(sendQueueProvider).values.expand((m) => m),
        isEmpty,
      );
    });

    testWidgets('grid enabled, close before denied screen tap', (
      WidgetTester t,
    ) async {
      final g = VideoGalleryFake(access: GalleryAccess.denied);
      final videos = DeviceVideosFake(
        pickResult: VideoPick(videos: [videoSource('a')]),
      );

      final container = await pumpVideoChat(
        t,
        world(),
        videos: videos,
        asRoute: true,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(true),
        ],
      );

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);

      await closeChat(t);

      await t.tap(byKey('video-phone-picker'));
      await frames(t);

      expect(videos.discarded, isEmpty);
      expect(videos.picks, 0);
      expect(
        container.read(sendQueueProvider).values.expand((m) => m),
        isEmpty,
      );
    });

    testWidgets('grid disabled, close after chooser, device pick completes', (
      WidgetTester t,
    ) async {
      final g = VideoGalleryFake();
      final videos = DeviceVideosFake()..heldPick = Completer<VideoPick>();

      final container = await pumpVideoChat(
        t,
        world(),
        videos: videos,
        asRoute: true,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(false),
        ],
      );

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);

      await closeChat(t);

      videos.heldPick!.complete(
        VideoPick(videos: [videoSource('a'), videoSource('b')]),
      );
      await frames(t);

      expect(videos.picks, 1);
      expect(videos.discarded, unorderedEquals(['a', 'b']));
      expect(
        container.read(sendQueueProvider).values.expand((m) => m),
        isEmpty,
      );
      expect(byKey('video-tile-a'), findsNothing);
    });

    testWidgets('grid disabled, close after review page, send', (
      WidgetTester t,
    ) async {
      final g = VideoGalleryFake();
      final videos = DeviceVideosFake(
        pickResult: VideoPick(videos: [videoSource('a'), videoSource('b')]),
      );

      final container = await pumpVideoChat(
        t,
        world(),
        videos: videos,
        asRoute: true,
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(false),
        ],
      );

      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);

      expect(byKey('video-tile-a'), findsOneWidget);

      await closeChat(t);

      await t.tap(byKey('video-send'));
      await frames(t);

      expect(videos.discarded, unorderedEquals(['a', 'b']));
      expect(
        container.read(sendQueueProvider).values.expand((m) => m),
        isEmpty,
      );
    });
  });

  group('VideoGridComposer failed videos (iPhone fix)', () {
    // Opens the grid, ticks one tile, sends, and answers prepare with [pick].
    Future<ProviderContainer> pickThroughGrid(
      WidgetTester t,
      VideoPick pick,
    ) async {
      final g = VideoGalleryFake(videos: galleryVideos(3));
      final container = await pumpVideoChat(
        t,
        world(),
        videos: DeviceVideosFake(),
        extra: [
          videoGalleryProvider.overrideWithValue(g),
          videoGridEnabledProvider.overrideWithValue(true),
        ],
      );
      await frames(t);
      await t.tap(byKey('composer-attach'));
      await frames(t);
      await t.tap(byKey('attach-video'));
      await frames(t);
      await t.tap(byKey('video-grid-v0'));
      await frames(t);
      await t.tap(byKey('video-send'));
      await frames(t);
      g.prepares.single.answer.complete(pick);
      await frames(t);
      return container;
    }

    SisNotice notice(WidgetTester t) =>
        t.widget<SisNotice>(find.byType(SisNotice));

    testWidgets('failed 1, no videos: error notice, nothing enqueued', (
      t,
    ) async {
      final container = await pickThroughGrid(t, const VideoPick(failed: 1));

      expect(find.byType(SisNotice), findsOneWidget);
      expect(notice(t).message, l10nEn.videoPickFailed(1));
      expect(notice(t).isError, isTrue);
      expect(find.text(l10nEn.videoPickFailed(1)), findsOneWidget);
      expect(
        container.read(sendQueueProvider).values.expand((m) => m),
        isEmpty,
      );
      expect(find.byKey(const Key('video-send')), findsNothing);
      await noticeGone(t);
    });

    testWidgets('failed 2, no videos: plural notice', (t) async {
      await pickThroughGrid(t, const VideoPick(failed: 2));

      expect(notice(t).message, l10nEn.videoPickFailed(2));
      expect(notice(t).isError, isTrue);
      await noticeGone(t);
    });

    testWidgets('1 good + 1 failed: notice and the good one is sent', (
      t,
    ) async {
      await pickThroughGrid(
        t,
        VideoPick(videos: [videoSource('a')], failed: 1),
      );

      expect(find.byKey(const Key('video-a')), findsOneWidget);
      expect(notice(t).message, l10nEn.videoPickFailed(1));
      expect(notice(t).isError, isTrue);
      await noticeGone(t);
    });

    testWidgets('failed 0, good video: no notice', (t) async {
      await pickThroughGrid(t, VideoPick(videos: [videoSource('a')]));

      expect(find.byKey(const Key('video-a')), findsOneWidget);
      expect(find.byType(SisNotice), findsNothing);
    });

    testWidgets('failed 0, too long 1: only the tooLong notice', (t) async {
      await pickThroughGrid(t, const VideoPick(tooLong: 1));

      expect(find.text(l10nEn.videoTooLong(1)), findsOneWidget);
      expect(find.text(l10nEn.videoPickFailed(1)), findsNothing);
      expect(find.byType(SisNotice), findsOneWidget);
      await noticeGone(t);
    });
  });
}

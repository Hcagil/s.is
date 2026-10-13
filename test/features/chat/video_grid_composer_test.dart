import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

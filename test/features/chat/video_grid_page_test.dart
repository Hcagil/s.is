import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/presentation/video_grid_page.dart';

import '../../support/l10n.dart';
import '../../support/video_fakes.dart';
import '../../support/video_gallery_fakes.dart';

/// Harness
typedef GridResult = ({VideoPick pick, bool phonePicker});

class Opened {
  bool done = false;
  GridResult? result;
}

Future<Opened> openGrid(
  WidgetTester t,
  VideoGalleryFake g, {
  Locale locale = const Locale('en'),
}) async {
  t.view.physicalSize = const Size(411, 891);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final opened = Opened();
  await t.pumpWidget(
    ProviderScope(
      overrides: [videoGalleryProvider.overrideWithValue(g)],
      child: localizedApp(
        locale: locale,
        theme: sisTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open-grid'),
                onPressed: () async {
                  opened.result = await showVideoGrid(context);
                  opened.done = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('open-grid')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 1));
  return opened;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Finder k(String key) => find.byKey(ValueKey(key));

void main() {
  testWidgets('1. Loading first', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    expect(find.byType(SisLoadingLogo), findsOneWidget);
    expect(k('video-grid-v0'), findsNothing);
    await settle(t);
    expect(k('video-grid-v0'), findsOneWidget);
    expect(k('video-grid-v1'), findsOneWidget);
    expect(k('video-grid-v2'), findsOneWidget);
  });

  testWidgets('2. Full access, 3 videos and duration labels', (
    WidgetTester t,
  ) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    expect(k('video-grid-v0'), findsOneWidget);
    expect(k('video-grid-v1'), findsOneWidget);
    expect(k('video-grid-v2'), findsOneWidget);
    expect(find.text(durationLabel(41000)), findsNWidgets(3));
  });

  testWidgets('2b. A 125 s video shows 2:05', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(1, durationMs: 125000),
    );
    await openGrid(t, g);
    await settle(t);
    expect(find.text(durationLabel(125000)), findsOneWidget);
  });

  testWidgets('3. Send button disabled at 0 ticks', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    final button = t.widget<FilledButton>(k('video-send'));
    expect(button.onPressed, isNull);
    expect(find.text(l10nEn.videoSendCount(0)), findsOneWidget);
  });

  testWidgets('4. Tick toggle', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    await t.tap(k('video-grid-v0'));
    await t.pump();
    await settle(t);
    expect(k('video-grid-tick-v0'), findsOneWidget);
    expect(find.text(l10nEn.videoSendCount(1)), findsOneWidget);
    final button = t.widget<FilledButton>(k('video-send'));
    expect(button.onPressed, isNotNull);

    await t.tap(k('video-grid-v0'));
    await t.pump();
    await settle(t);
    expect(k('video-grid-tick-v0'), findsNothing);
    expect(find.text(l10nEn.videoSendCount(0)), findsOneWidget);
    expect(t.widget<FilledButton>(k('video-send')).onPressed, isNull);
  });

  testWidgets('5. Tick order and untick', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    await t.tap(k('video-grid-v2'));
    await t.tap(k('video-grid-v0'));
    await t.tap(k('video-grid-v1'));
    await t.pump();
    await settle(t);
    await t.tap(k('video-send'));
    await t.pump();
    await settle(t);
    expect(g.prepares.length, 1);
    expect(g.prepares.single.chosen.map((v) => v.id).toList(), [
      'v2',
      'v0',
      'v1',
    ]);
  });

  testWidgets('5b. Unticking in the middle keeps the rest in tick order', (
    WidgetTester t,
  ) async {
    final g = VideoGalleryFake(videos: galleryVideos(3));
    await openGrid(t, g);
    await settle(t);
    for (final id in ['v2', 'v0', 'v1', 'v0']) {
      await t.tap(k('video-grid-$id'));
      await t.pump();
    }
    await t.tap(k('video-send'));
    await settle(t);
    expect(g.prepares.single.chosen.map((v) => v.id).toList(), ['v2', 'v1']);
  });

  testWidgets('6. While preparing', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    final opened = await openGrid(t, g);
    await settle(t);
    await t.tap(k('video-grid-v0'));
    await t.pump();
    await t.tap(k('video-send'));
    await t.pump();
    await settle(t);
    expect(k('video-send'), findsOneWidget);
    expect(opened.done, isFalse);
    expect(t.widget<FilledButton>(k('video-send')).onPressed, isNull);
    expect(find.byType(SisProgressLine), findsOneWidget);
    await t.tap(k('video-grid-v1'));
    await t.pump();
    await settle(t);
    expect(k('video-grid-tick-v1'), findsNothing);
    await t.binding.handlePopRoute();
    await settle(t);
    expect(k('video-send'), findsOneWidget);
    expect(opened.done, isFalse);

    g.prepares.single.answer.complete(
      VideoPick(videos: [videoSource('a')], tooLong: 1),
    );
    await settle(t);
    expect(opened.done, isTrue);
    expect(opened.result!.phonePicker, isFalse);
    expect(opened.result!.pick.videos.single.id, 'a');
    expect(opened.result!.pick.tooLong, 1);
    await t.pump(const Duration(seconds: 1));
    expect(k('video-send'), findsNothing);
  });

  testWidgets('7. Back with nothing ticked', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    final opened = await openGrid(t, g);
    await settle(t);
    await t.binding.handlePopRoute();
    await settle(t);
    expect(opened.done, isTrue);
    expect(opened.result, isNull);
  });

  testWidgets('8. Denied access flow', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.denied,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    expect(find.text(l10nEn.videoAllow), findsOneWidget);
    expect(find.text(l10nEn.videoAccessTitle), findsOneWidget);
    expect(find.text(l10nEn.videoAccessBody), findsOneWidget);
    expect(k('video-grid-v0'), findsNothing);

    g.access = GalleryAccess.full;
    await t.tap(k('video-allow'));
    await settle(t);
    expect(g.accessRequests, 2);
    expect(k('video-grid-v0'), findsOneWidget);
  });

  testWidgets('9. Permanently denied access', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.permanentlyDenied,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    expect(find.text(l10nEn.attachOpenSettings), findsOneWidget);
    await t.tap(k('video-allow'));
    await settle(t);
    expect(g.settingsOpened, 1);
  });

  testWidgets('10. Phone picker option', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.denied,
      videos: galleryVideos(3),
    );
    final opened = await openGrid(t, g);
    await settle(t);
    expect(find.text(l10nEn.videoUsePhonePicker), findsOneWidget);
    await t.tap(k('video-phone-picker'));
    await settle(t);
    expect(opened.done, isTrue);
    expect(opened.result!.phonePicker, isTrue);
    expect(opened.result!.pick.videos.isEmpty, isTrue);
    expect(opened.result!.pick.tooLong, 0);
  });

  testWidgets('11. Not now option', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.denied,
      videos: galleryVideos(3),
    );
    final opened = await openGrid(t, g);
    await settle(t);
    expect(find.text(l10nEn.attachNotNow), findsOneWidget);
    await t.tap(k('video-not-now'));
    await settle(t);
    expect(opened.done, isTrue);
    expect(opened.result, isNull);
  });

  testWidgets('12a. Reload on resume while denied', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.denied,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    g.access = GalleryAccess.full;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(t);
    expect(k('video-grid-v0'), findsOneWidget);
    expect(g.accessRequests, 2);
  });

  testWidgets('12b. Resume with full access does not ask again', (
    WidgetTester t,
  ) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g);
    await settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(t);
    expect(g.accessRequests, 1);
  });

  testWidgets('13. Limited access flow', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.limited,
      videos: galleryVideos(1),
    );
    await openGrid(t, g);
    await settle(t);
    expect(find.text(l10nEn.attachAllowMore), findsOneWidget);
    g.afterSelectMore = galleryVideos(2);
    await t.tap(k('video-allow-more'));
    await settle(t);
    expect(g.selectMores, 1);
    expect(k('video-grid-v1'), findsOneWidget);
    expect(g.accessRequests, 2);
  });

  testWidgets('14. Empty grid', (WidgetTester t) async {
    final g = VideoGalleryFake(access: GalleryAccess.full, videos: []);
    await openGrid(t, g);
    await settle(t);
    expect(find.text(l10nEn.videoGridEmpty), findsOneWidget);
  });

  testWidgets('15a. Paging with many videos', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(130),
    );
    await openGrid(t, g);
    await settle(t);
    expect(g.pagesAsked.first, (page: 0, count: 60));
    await t.drag(find.byType(GridView), const Offset(0, -20000));
    await settle(t);
    for (var i = 0; i < 5; i++) {
      if (g.pagesAsked.any((e) => e.page == 2)) break;
      await t.drag(find.byType(GridView), const Offset(0, -20000));
      await settle(t);
    }
    await t.drag(find.byType(GridView), const Offset(0, -20000));
    await settle(t);
    expect(g.pagesAsked, [
      (page: 0, count: 60),
      (page: 1, count: 60),
      (page: 2, count: 60),
    ]);
    expect(k('video-grid-v129'), findsOneWidget);
  });

  testWidgets('15b. Paging with 50 videos', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(50),
    );
    await openGrid(t, g);
    await settle(t);
    await t.drag(find.byType(GridView), const Offset(0, -20000));
    await settle(t);
    expect(g.pagesAsked.length, 1);
  });

  testWidgets('16. Load-more failure', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(130),
    )..failingPages.add(1);
    await openGrid(t, g);
    await settle(t);
    await t.drag(find.byType(GridView), const Offset(0, -20000));
    await settle(t);
    expect(find.text(l10nEn.videoLoadMoreFailed), findsOneWidget);
    expect(k('video-grid-v59'), findsOneWidget);
    expect(k('video-grid-v60'), findsNothing);
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('17a. Turkish denied access', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.denied,
      videos: galleryVideos(3),
    );
    await openGrid(t, g, locale: const Locale('tr'));
    await settle(t);
    expect(find.text(l10nTr.videoAllow), findsOneWidget);
    expect(find.text(l10nTr.videoUsePhonePicker), findsOneWidget);
    expect(find.text(l10nTr.attachNotNow), findsOneWidget);
    expect(find.text(l10nTr.videoAccessTitle), findsOneWidget);
  });

  testWidgets('17b. Turkish send count', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.full,
      videos: galleryVideos(3),
    );
    await openGrid(t, g, locale: const Locale('tr'));
    await settle(t);
    await t.tap(k('video-grid-v0'));
    await t.pump();
    await settle(t);
    expect(find.text(l10nTr.videoSendCount(1)), findsOneWidget);
  });

  testWidgets('17c. Turkish empty grid', (WidgetTester t) async {
    final g = VideoGalleryFake(access: GalleryAccess.full, videos: []);
    await openGrid(t, g, locale: const Locale('tr'));
    await settle(t);
    expect(find.text(l10nTr.videoGridEmpty), findsOneWidget);
  });

  testWidgets('17d. Turkish permanently denied', (WidgetTester t) async {
    final g = VideoGalleryFake(
      access: GalleryAccess.permanentlyDenied,
      videos: galleryVideos(3),
    );
    await openGrid(t, g, locale: const Locale('tr'));
    await settle(t);
    expect(find.text(l10nTr.attachOpenSettings), findsOneWidget);
  });
}

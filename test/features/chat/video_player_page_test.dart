import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/presentation/video_player_page.dart';

import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

Future<void> _launchVideo(
  WidgetTester t,
  VideoPlaybackFactoryFake factory,
  VideoSharerFake sharer,
) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: videoOverrides(playback: factory, sharer: sharer),
      child: localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('launch'),
            onPressed: () =>
                openVideoPlayer(context, '/app/files/v1/Beach day.mp4'),
            child: const Text('launch'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('launch')));
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  const path = '/app/files/v1/Beach day.mp4';

  testWidgets('1. Opening makes exactly one player and opens the given path', (
    WidgetTester t,
  ) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    expect(factory.made.length, 1);
    expect(factory.made.single.openedPath, path);
  });

  testWidgets('2. All five keys are found once the player is open', (
    WidgetTester t,
  ) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    expect(find.byKey(const ValueKey('video-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-mute')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-scrub')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-playpause')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-share')), findsOneWidget);
  });

  testWidgets('3. video-close pops the page and disposes the player', (
    WidgetTester t,
  ) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    await t.tap(find.byKey(const ValueKey('video-close')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-close')), findsNothing);
    expect(find.byKey(const ValueKey('launch')), findsOneWidget);
    expect(factory.made.single.calls.contains('dispose'), isTrue);
  });

  testWidgets('4. play/pause toggles correctly', (WidgetTester t) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    final playback = factory.made.single;

    playback.emit(
      const VideoPlaybackState(
        position: Duration.zero,
        duration: Duration(seconds: 41),
        playing: true,
        finished: false,
      ),
    );
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.byKey(const ValueKey('video-playpause')));
    await t.pump(const Duration(milliseconds: 50));
    expect(playback.calls.contains('pause'), isTrue);

    playback.emit(
      const VideoPlaybackState(
        position: Duration.zero,
        duration: Duration(seconds: 41),
        playing: false,
        finished: false,
      ),
    );
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.byKey(const ValueKey('video-playpause')));
    await t.pump(const Duration(milliseconds: 50));
    expect(playback.calls.last, 'play');
  });

  testWidgets('5. Mute toggles correctly', (WidgetTester t) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    final playback = factory.made.single;

    await t.tap(find.byKey(const ValueKey('video-mute')));
    await t.pump(const Duration(milliseconds: 50));
    expect(playback.calls.contains('muted:true'), isTrue);

    await t.tap(find.byKey(const ValueKey('video-mute')));
    await t.pump(const Duration(milliseconds: 50));
    expect(playback.calls.contains('muted:false'), isTrue);
  });

  testWidgets('6. Share button shares the file path', (WidgetTester t) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    await t.tap(find.byKey(const ValueKey('video-share')));
    await t.pump(const Duration(milliseconds: 50));
    expect(sharer.shared, [path]);
  });

  testWidgets('7. Scrubbing emits correct seek value', (WidgetTester t) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    final playback = factory.made.single;

    playback.emit(
      const VideoPlaybackState(
        position: Duration.zero,
        duration: Duration(seconds: 41),
        playing: true,
        finished: false,
      ),
    );
    await t.pump(const Duration(milliseconds: 50));

    final slider = find.byKey(const ValueKey('video-scrub'));
    final center = t.getCenter(slider);
    await t.tapAt(center);
    await t.pump(const Duration(milliseconds: 50));

    final seekCalls = playback.calls
        .where((c) => c.startsWith('seek:'))
        .toList();
    expect(seekCalls.isNotEmpty, isTrue);
    final ms = int.parse(seekCalls.first.split(':')[1]);
    expect(ms, inInclusiveRange(10000, 31000));
  });

  testWidgets('8. Cannot play message shown when opens=false (en)', (
    WidgetTester t,
  ) async {
    final factory = VideoPlaybackFactoryFake(opens: false);
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    expect(find.text(l10nEn.videoCannotPlay), findsOneWidget);
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('9. Cannot play message shown when opens=false (tr)', (
    WidgetTester t,
  ) async {
    final factory = VideoPlaybackFactoryFake(opens: false);
    final sharer = VideoSharerFake();
    await t.pumpWidget(
      ProviderScope(
        overrides: videoOverrides(playback: factory, sharer: sharer),
        child: localizedApp(
          locale: const Locale('tr'),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('launch'),
              onPressed: () => openVideoPlayer(context, path),
              child: const Text('launch'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('launch')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(l10nTr.videoCannotPlay), findsOneWidget);
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('10. System back disposes the player', (WidgetTester t) async {
    final factory = VideoPlaybackFactoryFake();
    final sharer = VideoSharerFake();
    await _launchVideo(t, factory, sharer);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('launch')), findsOneWidget);
    expect(factory.made.single.calls.contains('dispose'), isTrue);
  });
}

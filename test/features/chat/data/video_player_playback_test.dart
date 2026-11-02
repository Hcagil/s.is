import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/video_player_playback.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// A platform whose players fail to initialise for the view types in [failing].
class _FakePlatform extends VideoPlayerPlatform {
  _FakePlatform(this.failing);

  final Set<VideoViewType> failing;
  final created = <int, VideoViewType>{};
  final disposed = <int>[];
  var _next = 1;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    created[id] = options.viewType;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final c = StreamController<VideoEvent>();
    c.onListen = () {
      if (failing.contains(created[playerId])) {
        c.addError(
          PlatformException(code: 'VideoError', message: 'no surface'),
        );
      } else {
        c.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 3),
            size: const Size(10, 10),
          ),
        );
      }
    };
    return c.stream;
  }

  @override
  Future<void> dispose(int playerId) async => disposed.add(playerId);

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool value,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VideoPlayerPlatform original;
  setUp(() => original = VideoPlayerPlatform.instance);
  tearDown(() => VideoPlayerPlatform.instance = original);

  _FakePlatform install(Set<VideoViewType> failing) {
    final p = _FakePlatform(failing);
    VideoPlayerPlatform.instance = p;
    return p;
  }

  test('texture view works: one controller, no retry', () async {
    final p = install({});
    final playback = VideoPlayerPlayback();
    expect(await playback.open('/tmp/a.mp4'), isTrue);
    expect(p.created.values, [VideoViewType.textureView]);
    expect(p.disposed, isEmpty);
    expect(playback.controller, isNotNull);
  });

  test(
    'texture fails, platform view works: retried and failed one disposed',
    () async {
      final p = install({VideoViewType.textureView});
      final playback = VideoPlayerPlayback();
      expect(await playback.open('/tmp/a.mp4'), isTrue);
      expect(p.created.values, [
        VideoViewType.textureView,
        VideoViewType.platformView,
      ]);
      expect(p.disposed, [1]);
      expect(playback.controller!.viewType, VideoViewType.platformView);
    },
  );

  test('both fail: false, no controller, both disposed', () async {
    final p = install({...VideoViewType.values});
    final playback = VideoPlayerPlayback();
    expect(await playback.open('/tmp/a.mp4'), isFalse);
    expect(p.created.length, 2);
    expect(p.disposed, [1, 2]);
    expect(playback.controller, isNull);
  });

  test('a second open disposes the old controller', () async {
    final p = install({});
    final playback = VideoPlayerPlayback();
    await playback.open('/tmp/a.mp4');
    await playback.open('/tmp/b.mp4');
    expect(p.disposed, [1]);
    expect(p.created.length, 2);
    expect(playback.controller, isNotNull);
  });
}

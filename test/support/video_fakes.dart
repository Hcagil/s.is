// Fakes for the video boundary (DeviceVideos, VideoPlayback, VideoSharer) and
// the send-queue store, written by QA from the interfaces only. They are
// inconvenient like the real ones: shrinking is held until the test answers
// it and reports progress first, cancelling makes the running shrink answer
// VideoCancelledFailure, a player opens late and its states arrive on a
// stream, and the store keeps only what survives its JSON encoding.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/presentation/video_player_page.dart';

/// A picked video, as DeviceVideos.pick hands it over (copied to [path]).
VideoSource videoSource(
  String id, {
  String name = 'Beach day.mov',
  int size = 31457280,
  int durationMs = 41000,
  int width = 1920,
  int height = 1080,
}) => VideoSource(
  id: id,
  path: '/app/videos/$id/$name',
  name: name,
  size: size,
  durationMs: durationMs,
  width: width,
  height: height,
  thumbPath: '/app/videos/$id/thumb.jpg',
);

/// The file compress keeps for [v], as the real one names it.
PickedFile shrunk(VideoSource v, {int size = 8388608}) => PickedFile(
  id: v.id,
  path: '/app/files/${v.id}/${videoFileName(v.name)}',
  name: videoFileName(v.name),
  mime: videoMime,
  size: size,
  durationMs: v.durationMs,
  thumbPath: v.thumbPath,
);

/// One shrink asked of the phone, waiting for the test's answer.
class CompressAsk {
  CompressAsk(this.source, this.onProgress);
  final VideoSource source;
  final void Function(double fraction)? onProgress;
  final answer = Completer<Result<PickedFile>>();
}

/// [DeviceVideos] whose every shrink is held until the test answers it.
class DeviceVideosFake implements DeviceVideos {
  DeviceVideosFake({this.pickResult = const VideoPick()});

  VideoPick pickResult;

  /// When set, pick() answers only once the test completes it (the phone's
  /// chooser is still open).
  Completer<VideoPick>? heldPick;
  int picks = 0;
  int cancels = 0;
  final compressions = <CompressAsk>[];
  final discarded = <String>[];

  @override
  Future<VideoPick> pick() async {
    picks++;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final held = heldPick;
    if (held != null) return held.future;
    return pickResult;
  }

  @override
  Future<Result<PickedFile>> compress(
    VideoSource source, {
    void Function(double fraction)? onProgress,
  }) {
    final ask = CompressAsk(source, onProgress);
    compressions.add(ask);
    return ask.answer.future;
  }

  void progress(int i, double f) => compressions[i].onProgress?.call(f);

  void compressOk(int i, {int size = 8388608}) => compressions[i].answer
      .complete(Ok(shrunk(compressions[i].source, size: size)));

  void compressFail(int i, Failure f) =>
      compressions[i].answer.complete(Err(f));

  /// Like the real one: the running shrink stops and answers Cancelled.
  @override
  Future<void> cancelCompression() async {
    cancels++;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    for (final a in compressions) {
      if (!a.answer.isCompleted) {
        a.answer.complete(const Err(VideoCancelledFailure()));
      }
    }
  }

  @override
  Future<void> discard(VideoSource source) async {
    discarded.add(source.id);
  }
}

/// [SendQueueStore] that keeps what it was given as the encoded JSON the real
/// one writes, so only what survives encodeQueue/decodeQueue comes back.
class SendQueueStoreFake implements SendQueueStore {
  /// How late load answers; zero (a microtask) unless a test asks, so a
  /// harness that never restores leaves no timer behind.
  SendQueueStoreFake({this.latency = Duration.zero});
  final Duration latency;
  final saved = <String, String>{};
  int saves = 0;
  int clears = 0;

  @override
  Future<List<QueuedRecord>> load(String userId) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    return decodeQueue(saved[userId]);
  }

  @override
  Future<void> save(String userId, List<QueuedRecord> records) async {
    saves++;
    if (records.isEmpty) {
      saved.remove(userId);
    } else {
      saved[userId] = encodeQueue(records);
    }
  }

  @override
  Future<void> clear() async {
    clears++;
    saved.clear();
  }

  List<QueuedRecord> records(String userId) => decodeQueue(saved[userId]);
}

/// A player that opens late and reports through [states].
class VideoPlaybackFake implements VideoPlayback {
  VideoPlaybackFake({this.opens = true});
  bool opens;
  final calls = <String>[];
  String? openedPath;
  final _states = StreamController<VideoPlaybackState>.broadcast();

  void emit(VideoPlaybackState s) => _states.add(s);

  @override
  Future<bool> open(String path) async {
    openedPath = path;
    calls.add('open');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return opens;
  }

  @override
  Stream<VideoPlaybackState> get states => _states.stream;

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekTo(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setMuted(bool muted) async => calls.add('muted:$muted');

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _states.close();
  }
}

class VideoPlaybackFactoryFake implements VideoPlaybackFactory {
  VideoPlaybackFactoryFake({this.opens = true});
  bool opens;
  final made = <VideoPlaybackFake>[];

  @override
  VideoPlayback create() {
    final p = VideoPlaybackFake(opens: opens);
    made.add(p);
    return p;
  }
}

class VideoSharerFake implements VideoSharer {
  final shared = <String>[];

  @override
  Future<void> share(String path) async => shared.add(path);
}

/// The overrides every harness mounting the queue or the chat screen needs;
/// pass a fake to inspect it.
List<Override> videoOverrides({
  SendQueueStore? store,
  DeviceVideos? videos,
  VideoPlaybackFactory? playback,
  VideoSharer? sharer,
}) => [
  sendQueueStoreProvider.overrideWithValue(store ?? SendQueueStoreFake()),
  deviceVideosProvider.overrideWithValue(videos ?? DeviceVideosFake()),
  videoPlaybackFactoryProvider.overrideWithValue(
    playback ?? VideoPlaybackFactoryFake(),
  ),
  videoSharerProvider.overrideWithValue(sharer ?? VideoSharerFake()),
  videoSurfaceProvider.overrideWithValue(
    (_) => const SizedBox(key: Key('video-surface')),
  ),
];

import 'dart:math' as math;

import '../../../core/failure.dart';
import 'file_attachment.dart';

const int maxVideoMs = 300000; // a video may be at most 5 minutes
const int videoShortSide =
    720; // a video is shrunk so its short side is at most 720 px
const String videoMime = 'video/mp4';
const String videoPreview =
    '\u{1F3A5} Video'; // the one-line preview / quote / forward text

bool isVideoTooLong(int durationMs) => durationMs > maxVideoMs;

/// m:ss of a length, minutes not capped, seconds rounded from ms: 41000 -> '0:41', 65400 -> '1:05'.
String durationLabel(int ms) {
  final total = (ms / 1000).round();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// The size a video is shrunk to: aspect kept, short side at most videoShortSide, never larger than the original, both sides even (round down to even, minimum 2).
({int width, int height}) videoTargetSize(int width, int height) {
  int even(int v) => math.max(2, v - v % 2);
  final short = math.min(width, height);
  if (short <= videoShortSide) {
    return (width: even(width), height: even(height));
  }
  final scale = videoShortSide / short;
  return (
    width: even((width * scale).round()),
    height: even((height * scale).round()),
  );
}

/// The file name a shrunk video is sent under: the original name without its extension, cleaned, plus '.mp4'.
String videoFileName(String original) {
  final lastDot = original.lastIndexOf('.');
  final base = lastDot > 0 ? original.substring(0, lastDot) : original;
  return '${safeFileName(base)}.mp4';
}

/// A video the member picked, copied into the app's own folder, not yet shrunk.
final class VideoSource {
  /// Creates a video source with the given properties.
  const VideoSource({
    required this.id,
    required this.path,
    required this.name,
    required this.size,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.thumbPath,
  });

  /// The ID of the message that will carry this video.
  final String id;

  /// The path to the video in the app's own folder.
  final String path;

  /// The video's original name.
  final String name;

  /// The video's size in bytes.
  final int size;

  /// The video's length in milliseconds.
  final int durationMs;

  /// The video's width in pixels.
  final int width;

  /// The video's height in pixels.
  final int height;

  /// The path of the video's jpeg thumbnail on this phone.
  final String thumbPath;

  /// The bubble data of this video while it waits to be shrunk and sent: named as it will be sent.
  AttachedFile get attached => AttachedFile(
    name: videoFileName(name),
    mime: videoMime,
    size: size,
    durationMs: durationMs,
    thumbPath: thumbPath,
  );
}

/// What the video chooser returned.
final class VideoPick {
  /// Creates a video pick with the given properties.
  const VideoPick({this.videos = const [], this.tooLong = 0});

  /// The list of picked videos that are within duration limits.
  final List<VideoSource> videos;

  /// The number of picked videos that exceeded [maxVideoMs].
  final int tooLong;
}

/// The boundary for picking and shrinking videos on the device. Never throws.
abstract interface class DeviceVideos {
  /// Opens the system video chooser (several allowed). Each usable video is copied into the app's own folder and described by a VideoSource; videos longer than maxVideoMs are only counted in VideoPick.tooLong. Cancelled or failed: an empty VideoPick.
  Future<VideoPick> pick();

  /// Shrinks to videoTargetSize (mp4), reporting 0..1 in onProgress; returns the file kept for the message (PickedFile with mime videoMime, name videoFileName(source.name), durationMs and thumbPath set). Err(VideoTooBigFailure()) when the result is over maxFileBytes, Err(VideoCancelledFailure()) after cancelCompression, Err(VideoFailedFailure()) on any other failure. The source copy is deleted when it succeeded.
  Future<Result<PickedFile>> compress(
    VideoSource source, {
    void Function(double fraction)? onProgress,
  });

  /// Stops the running compress.
  Future<void> cancelCompression();

  /// Deletes everything kept for the source (video copy and picture).
  Future<void> discard(VideoSource source);
}

/// A video being played. Never throws.
abstract interface class VideoPlayback {
  /// Prepares the video file at path; false when it cannot be played.
  Future<bool> open(String path);

  /// The stream of playback states.
  Stream<VideoPlaybackState> get states;

  /// Starts playing the video.
  Future<void> play();

  /// Pauses the video.
  Future<void> pause();

  /// Seeks to the given position.
  Future<void> seekTo(Duration position);

  /// Sets whether the video is muted.
  Future<void> setMuted(bool muted);

  /// Disposes of the video player.
  Future<void> dispose();
}

/// A snapshot of playback.
final class VideoPlaybackState {
  /// Creates a video playback state with the given properties.
  const VideoPlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.finished = false,
  });

  /// The current position in the video.
  final Duration position;

  /// The total duration of the video.
  final Duration duration;

  /// Whether the video is currently playing.
  final bool playing;

  /// Whether the video has finished playing.
  final bool finished;
}

/// Makes a VideoPlayback for each player screen.
abstract interface class VideoPlaybackFactory {
  /// Creates a new video playback instance.
  VideoPlayback create();
}

/// Hands a file to the phone's share sheet.
abstract interface class VideoSharer {
  /// Shares the video at the given path.
  Future<void> share(String path);
}

/// Where a video being sent is, shown on its bubble.
enum VideoStage {
  /// Being shrunk on this phone.
  compressing,

  /// Being uploaded.
  sending,

  /// Waiting for the network to come back.
  waiting,
}

/// A video send's stage with how far it is (0..1) when that is known.
final class VideoProgress {
  /// Creates the progress of a video send.
  const VideoProgress(this.stage, [this.fraction = 0]);

  /// Which stage the video is in.
  final VideoStage stage;

  /// How far this stage is, 0..1.
  final double fraction;
}

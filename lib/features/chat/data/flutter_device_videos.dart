import 'dart:developer';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;

import '../../../core/failure.dart';
import '../domain/file_attachment.dart';
import '../domain/file_repository.dart';
import '../domain/video.dart';
import 'video_source_prep.dart';

/// Picks videos with the system picker and shrinks them to about 720p.
///
/// Every file of a video lives in the message's own folder from [DeviceFiles].
final class FlutterDeviceVideos implements DeviceVideos {
  /// Creates the video device; [compressor] is replaceable for tests.
  FlutterDeviceVideos(this._files, {lc.LightCompressor? compressor})
    : _lc = compressor ?? lc.LightCompressor();

  final DeviceFiles _files;
  final lc.LightCompressor _lc;

  @override
  Future<VideoPick> pick() async {
    try {
      final picked = await FilePicker.pickFiles(type: FileType.video);
      var tooLong = 0;
      final videos = <VideoSource>[];
      for (final f in picked) {
        final result = await prepareVideoSource(
          files: _files,
          compressor: _lc,
          name: safeFileName(f.name),
          bytes: f.readAsByteStream(),
        );
        final source = result.source;
        if (source != null) {
          videos.add(source);
        } else if (result.tooLong) {
          tooLong++;
        }
      }
      return VideoPick(videos: videos, tooLong: tooLong);
    } catch (e) {
      log('Picking videos failed: ${e.runtimeType}', name: 'sis.video');
      return const VideoPick();
    }
  }

  @override
  Future<Result<PickedFile>> compress(
    VideoSource source, {
    void Function(double fraction)? onProgress,
  }) async {
    try {
      final sub = _lc.onProgressUpdated.listen(
        (p) => onProgress?.call((p / 100).clamp(0.0, 1.0).toDouble()),
      );
      try {
        final target = videoTargetSize(source.width, source.height);
        final outName = videoFileName(source.name);
        final result = await _lc.compressVideo(
          path: source.path,
          videoQuality: lc.VideoQuality.medium,
          android: lc.AndroidConfig(isSharedStorage: false),
          ios: lc.IOSConfig(saveInGallery: false),
          video: lc.Video(
            videoName: outName,
            videoWidth: target.width,
            videoHeight: target.height,
          ),
          isMinBitrateCheckEnabled: false,
        );
        switch (result) {
          case lc.OnSuccess():
            final dest = await _files.pathFor(source.id, outName);
            await File(result.destinationPath).copy(dest);
            try {
              await File(result.destinationPath).delete();
            } catch (_) {}
            final size = await File(dest).length();
            if (size > maxFileBytes) {
              await File(dest).delete();
              return const Err(VideoTooBigFailure());
            }
            if (size <= 0) {
              await File(dest).delete();
              return const Err(VideoFailedFailure());
            }
            try {
              await File(source.path).delete();
            } catch (_) {}
            return Ok(
              PickedFile(
                id: source.id,
                path: dest,
                name: outName,
                mime: videoMime,
                size: size,
                durationMs: source.durationMs,
                thumbPath: source.thumbPath,
              ),
            );
          case lc.OnCancelled():
            return const Err(VideoCancelledFailure());
          default:
            return const Err(VideoFailedFailure());
        }
      } finally {
        await sub.cancel();
      }
    } catch (e) {
      log('Shrinking a video failed: ${e.runtimeType}', name: 'sis.video');
      return const Err(VideoFailedFailure());
    }
  }

  @override
  Future<void> cancelCompression() async {
    try {
      await _lc.cancelCompression();
    } catch (_) {}
  }

  @override
  Future<void> discard(VideoSource source) async {
    try {
      final dir = File(source.path).parent;
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

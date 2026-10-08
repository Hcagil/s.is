import 'dart:developer';
import 'dart:io';

import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;

import '../domain/file_repository.dart';
import '../domain/message.dart';
import '../domain/video.dart';

/// Copies one video's bytes into the message's own folder, reads its length
/// and size, rejects it when it is over [maxVideoMs], and saves its jpeg
/// thumbnail. Never throws. Returns the usable [VideoSource]; or `tooLong`
/// true when it is too long; or neither when it cannot be read. The folder is
/// deleted in both failing cases.
Future<({VideoSource? source, bool tooLong})> prepareVideoSource({
  required DeviceFiles files,
  required lc.LightCompressor compressor,
  required String name,
  required Stream<List<int>> bytes,
}) async {
  final id = randomMessageId();
  final dest = File(await files.pathFor(id, 'source'));
  try {
    await dest.parent.create(recursive: true);
    final sink = dest.openWrite();
    await sink.addStream(bytes);
    await sink.close();
    final info = await compressor.getMediaInfo(dest.path);
    final duration = info.duration;
    final width = info.width;
    final height = info.height;
    if (duration == null || width == null || height == null) {
      await dest.parent.delete(recursive: true);
      return (source: null, tooLong: false);
    }
    final ms = duration.inMilliseconds;
    if (isVideoTooLong(ms)) {
      await dest.parent.delete(recursive: true);
      return (source: null, tooLong: true);
    }
    final shot = await compressor.getVideoThumbnail(dest.path, quality: 40);
    final thumbDest = await files.pathFor(id, 'thumb.jpg');
    await File(shot).copy(thumbDest);
    try {
      await File(shot).delete();
    } catch (_) {}
    return (
      source: VideoSource(
        id: id,
        path: dest.path,
        name: name,
        size: await dest.length(),
        durationMs: ms,
        width: width,
        height: height,
        thumbPath: thumbDest,
      ),
      tooLong: false,
    );
  } catch (e) {
    log('Preparing a picked video failed: ${e.runtimeType}', name: 'sis.video');
    try {
      await dest.parent.delete(recursive: true);
    } catch (_) {}
    return (source: null, tooLong: false);
  }
}

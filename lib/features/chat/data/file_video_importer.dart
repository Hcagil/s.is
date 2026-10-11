import 'dart:developer';
import 'dart:io';

import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;

import '../domain/file_attachment.dart';
import '../domain/file_repository.dart';
import '../domain/shared_content.dart';
import '../domain/video.dart';
import 'video_source_prep.dart';

/// Copies a shared video into the app's own folder like a picked one.
final class FileVideoImporter implements SharedVideoImporter {
  /// Creates the importer; [compressor] is replaceable for tests.
  FileVideoImporter(this._files, {lc.LightCompressor? compressor})
    : _lc = compressor ?? lc.LightCompressor();

  final DeviceFiles _files;
  final lc.LightCompressor _lc;

  @override
  Future<({VideoSource? source, bool tooLong})> importVideo(
    SharedItem item,
  ) async {
    try {
      return await prepareVideoSource(
        files: _files,
        compressor: _lc,
        name: safeFileName(item.name),
        bytes: File(item.path).openRead(),
      );
    } catch (e) {
      log(
        'Importing a shared video failed: ${e.runtimeType}',
        name: 'sis.video',
      );
      return (source: null, tooLong: false);
    }
  }
}

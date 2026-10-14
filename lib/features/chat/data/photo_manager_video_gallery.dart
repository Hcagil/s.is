import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../domain/file_attachment.dart';
import '../domain/file_repository.dart';
import '../domain/gallery.dart';
import '../domain/video.dart';
import '../domain/video_gallery.dart';
import 'photo_manager_gallery.dart' show requestLibraryAccess, retryOnce;
import 'video_source_prep.dart';

/// The phone's video library through photo_manager. Thin on purpose
/// (ARCHITECTURE rule 4): verified on a device. Videos only.
final class PhotoManagerVideoGallery implements VideoGallery {
  /// Creates the video gallery; [compressor] is replaceable for tests.
  PhotoManagerVideoGallery(
    this._files, {
    lc.LightCompressor? compressor,
    Future<File?> Function(AssetEntity)? originFile,
  }) : _lc = compressor ?? lc.LightCompressor(),
       _originFile = originFile ?? ((e) => e.originFile);

  final DeviceFiles _files;
  final lc.LightCompressor _lc;

  /// Resolves an asset's file; replaceable because photo_manager asserts the
  /// platform, so tests cannot reach the real call off a phone.
  final Future<File?> Function(AssetEntity) _originFile;

  @override
  Future<GalleryAccess> requestAccess() =>
      requestLibraryAccess(RequestType.video);

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  Future<void> selectMore() =>
      PhotoManager.presentLimited(type: RequestType.video);

  @override
  Future<List<GalleryVideo>> recent({int page = 0, int count = 60}) async {
    // Newest first. Without an explicit order photo_manager sends Android
    // no sort at all and Android's default order comes back oldest first.
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate)],
      ),
    );
    if (paths.isEmpty) return const [];
    final assets = await paths.first.getAssetListPaged(page: page, size: count);
    return [
      for (final a in assets)
        GalleryVideo(id: a.id, durationMs: a.duration * 1000),
    ];
  }

  @override
  Future<Uint8List?> thumbnail(GalleryVideo video, {int size = 240}) async {
    final e = await AssetEntity.fromId(video.id);
    if (e == null) return null;
    return retryOnce(() => e.thumbnailDataWithSize(ThumbnailSize.square(size)));
  }

  @override
  Future<VideoPick> prepare(List<GalleryVideo> chosen) async {
    var tooLong = 0;
    var failed = 0;
    final videos = <VideoSource>[];
    try {
      for (final v in chosen) {
        try {
          final e = await AssetEntity.fromId(v.id);
          if (e == null) {
            failed++;
            continue;
          }
          // A clearly too-long file is not copied at all; the exact check
          // (the length read from the file itself) is in prepareVideoSource.
          if (e.duration > maxVideoMs ~/ 1000 + 1) {
            tooLong++;
            continue;
          }
          final file = await _originFile(e);
          if (file == null) {
            failed++;
            continue;
          }
          final result = await prepareVideoSource(
            files: _files,
            compressor: _lc,
            name: safeFileName(await e.titleAsync),
            bytes: file.openRead(),
            extension: p.extension(file.path).replaceFirst('.', ''),
          );
          final source = result.source;
          if (source != null) {
            videos.add(source);
          } else if (result.tooLong) {
            tooLong++;
          } else {
            failed++;
          }
        } catch (err) {
          failed++;
          log(
            'Preparing a gallery video failed: ${err.runtimeType}',
            name: 'sis.video',
          );
        }
      }
    } finally {
      try {
        await PhotoManager.clearFileCache();
      } catch (_) {}
    }
    return VideoPick(videos: videos, tooLong: tooLong, failed: failed);
  }
}

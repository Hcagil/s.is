import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../domain/attachment.dart';
import '../domain/gallery.dart';
import 'tiny_preview.dart';

/// The phone's photo library through photo_manager. Thin on purpose
/// (ARCHITECTURE rule 4): verified on a device. Images only; video and audio
/// are never asked for.
final class PhotoManagerGallery implements Gallery {
  const PhotoManagerGallery();

  /// Long edge of a sent photo, as for the system picker.
  static const _maxEdge = 1600;

  @override
  Future<GalleryAccess> requestAccess() async {
    final s = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );
    return s.isAuth
        ? GalleryAccess.full
        : s.hasAccess
        ? GalleryAccess.limited
        : GalleryAccess.denied;
  }

  @override
  Future<List<GalleryPhoto>> recent({int count = 60}) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (paths.isEmpty) return const [];
    final assets = await paths.first.getAssetListPaged(page: 0, size: count);
    return [for (final a in assets) GalleryPhoto(a.id)];
  }

  @override
  Future<Uint8List?> thumbnail(GalleryPhoto photo, {int size = 240}) async {
    final e = await AssetEntity.fromId(photo.id);
    return e?.thumbnailDataWithSize(ThumbnailSize.square(size));
  }

  @override
  Future<PickedImage?> load(GalleryPhoto photo) async {
    final e = await AssetEntity.fromId(photo.id);
    if (e == null) return null;
    final w = e.width, h = e.height;
    final long = w > h ? w : h;
    // An unknown size (0) asks for the cap and lets the platform fit it.
    final size = long == 0
        ? const ThumbnailSize(_maxEdge, _maxEdge)
        : long <= _maxEdge
        ? ThumbnailSize(w, h)
        : ThumbnailSize(
            (w * _maxEdge / long).round(),
            (h * _maxEdge / long).round(),
          );
    final bytes = await e.thumbnailDataWithSize(
      size,
      format: ThumbnailFormat.jpeg,
      quality: 85,
    );
    if (bytes == null) return null;
    return PickedImage(
      bytes: bytes,
      contentType: 'image/jpeg',
      extension: 'jpg',
      preview: await tinyPreview(bytes),
    );
  }

  @override
  Future<void> selectMore() =>
      PhotoManager.presentLimited(type: RequestType.image);
}

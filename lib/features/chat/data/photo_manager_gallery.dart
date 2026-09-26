import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// photo_manager (and Android) never says "permanently denied" directly:
  /// the OS silently stops showing its own prompt once the member has
  /// refused once already. So: remember that a refusal was shown, and read
  /// a second refusal as permanent. Ceiling: a member who denies, quits
  /// without asking again, then later taps deny from a cold app state is
  /// read the same way on their next ask -- indistinguishable from here.
  static const _askedBeforeKey = 'gallery_permission_asked_before';

  @override
  Future<GalleryAccess> requestAccess() async {
    final prefs = await SharedPreferences.getInstance();
    final askedBefore = prefs.getBool(_askedBeforeKey) ?? false;
    final s = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );
    if (s.isAuth) return GalleryAccess.full;
    if (s.hasAccess) return GalleryAccess.limited;
    if (askedBefore) return GalleryAccess.permanentlyDenied;
    await prefs.setBool(_askedBeforeKey, true);
    return GalleryAccess.denied;
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  Future<List<GalleryPhoto>> recent({int count = 60}) async {
    // Newest first. Without an explicit order photo_manager sends Android
    // no sort at all and Android's default order comes back oldest first.
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate)],
      ),
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

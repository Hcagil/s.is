import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../chat/domain/external_picker.dart';
import '../domain/wallpaper_photos.dart';

/// [WallpaperPhotos] over the existing one-photo chooser. The chosen photo is
/// copied into the app's own folder (its source is a temporary file). Thin on
/// purpose (ARCHITECTURE rule 4): verified on a device, not by a unit test.
final class PickerWallpaperPhotos implements WallpaperPhotos {
  const PickerWallpaperPhotos(this._picker);

  final ExternalPicker _picker;

  @override
  Future<WallpaperPick> pick() async {
    final result = await _picker.pickProfilePicture();
    return switch (result) {
      ExternalPickCancelled() => const WallpaperPickCancelled(),
      ExternalPickFailed() => const WallpaperPickFailed(),
      ExternalPickedImages(:final images) =>
        images.isEmpty
            ? const WallpaperPickCancelled()
            : await _saveImage(images.first.bytes),
    };
  }

  /// Saves [bytes] to a new file in the app's support directory, with a
  /// unique name so the image cache never shows a stale picture.
  Future<WallpaperPick> _saveImage(Uint8List bytes) async {
    try {
      final dir = (await getApplicationSupportDirectory()).path;
      final path =
          '$dir/wallpaper_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(bytes, flush: true);
      return WallpaperPicked(path);
    } catch (e) {
      log('wallpaper save failed: ${e.runtimeType}', name: 'sis.appearance');
      return const WallpaperPickFailed();
    }
  }

  @override
  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // A missed delete costs disk only, not correctness.
    }
  }
}

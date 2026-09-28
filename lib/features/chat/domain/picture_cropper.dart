import 'dart:typed_data';

import 'attachment.dart';

/// Crops a picture (a profile or group photo) on the phone: takes an
/// upright, already-decoded source photo and the square the member framed
/// with their fingers on the crop screen, and returns one small square JPEG
/// ready to upload.
///
/// Its own boundary (like the gallery and the external picker) because
/// turning pixels into a JPEG is a platform capability with no Dart-side
/// codec for it; the Android implementation reuses the same native
/// decode/encode path as the external picker.
abstract interface class PictureCropper {
  /// Crops [source] (an upright, already-decoded JPEG, the shape
  /// `Gallery.loadForCrop` or `ExternalPicker.pickProfilePicture` return) to
  /// the rectangle [left]..[right] horizontally and [top]..[bottom]
  /// vertically -- each a fraction from 0 to 1 of the source's width or
  /// height -- then scales that square to [size] px and encodes it as a
  /// JPEG at [quality]. Null when the source cannot be read or the crop
  /// fails.
  Future<PickedImage?> crop(
    Uint8List source, {
    required double left,
    required double top,
    required double right,
    required double bottom,
    int size = 640,
    int quality = 82,
  });
}

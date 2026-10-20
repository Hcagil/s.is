import 'attachment.dart';

/// Turns a photo and cuts a rectangle out of it, on the phone, for the free
/// crop screen.
///
/// Its own boundary because turning pixels into a PNG is a platform
/// capability.
abstract interface class PhotoCropRenderer {
  /// Turns [source] by [turns] quarter turns anticlockwise, then cuts out the
  /// rectangle [left]..[right] / [top]..[bottom] (fractions 0..1 of the TURNED
  /// photo) and returns it as a PNG [PickedImage] (longest side at most 2048
  /// px, same photoGroup as [source]). Null when the photo cannot be read or
  /// cut.
  Future<PickedImage?> render(
    PickedImage source, {
    required int turns,
    required double left,
    required double top,
    required double right,
    required double bottom,
  });
}

import 'dart:typed_data';

/// An image the member chose, before it is uploaded.
final class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.contentType,
    required this.extension,
  });

  final Uint8List bytes;
  final String contentType;

  /// Without the dot, e.g. `jpg`.
  final String extension;
}

/// Where a [PickedImage] comes from.
///
/// Its own boundary because choosing an image is a platform capability, and
/// `presentation/` may not import a platform SDK. The picker returns null when
/// the member backs out, which is not a failure.
abstract interface class AttachmentSource {
  Future<PickedImage?> pickImage();
}

import 'dart:typed_data';

/// An image the member chose, before it is uploaded.
final class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.contentType,
    required this.extension,
    this.preview,
  });

  final Uint8List bytes;
  final String contentType;

  /// Without the dot, e.g. `jpg`.
  final String extension;

  /// A tiny version (about 24 px wide), sent with the message so a receiver
  /// sees a blurred preview at once. Null when one could not be made.
  final Uint8List? preview;
}

/// Where a [PickedImage] comes from.
///
/// Its own boundary because choosing an image is a platform capability, and
/// `presentation/` may not import a platform SDK. The picker returns null when
/// the member backs out, which is not a failure.
abstract interface class AttachmentSource {
  Future<PickedImage?> pickImage();
}

/// Photos already on this phone, keyed by storage path, so a photo is
/// downloaded once rather than on every look. The signed URL changes each
/// time; the path does not.
abstract interface class AttachmentCache {
  /// The cached bytes for [path], or null when it is not here.
  Future<Uint8List?> read(String path);

  Future<void> write(String path, Uint8List bytes);

  /// Forgets one photo: it was deleted for everyone.
  Future<void> remove(String path);

  /// Forgets every cached photo: called on sign-out, so the next account on
  /// this phone does not inherit the last one's photos.
  Future<void> clear();
}

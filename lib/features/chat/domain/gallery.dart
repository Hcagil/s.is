import 'dart:typed_data';

import 'attachment.dart';

/// What access the member granted to the photo library.
enum GalleryAccess {
  /// The member allowed every photo on the phone.
  full,

  /// The member selected a subset of photos (Android 14+).
  limited,

  /// The member denied access.
  denied,
}

/// One photo on the phone, by the platform's id; its pixels are fetched on
/// demand.
final class GalleryPhoto {
  const GalleryPhoto(this.id);

  final String id;
}

/// The phone's own photos, for the attachment sheet's grid.
///
/// Its own boundary because reading the photo library is a platform capability
/// that needs the member's permission.
abstract interface class Gallery {
  /// Asks for permission the first time; afterwards answers without asking
  /// again.
  Future<GalleryAccess> requestAccess();

  /// The newest photos the member allowed, newest first; empty without access.
  Future<List<GalleryPhoto>> recent({int count = 60});

  /// A small square-ish version for the grid, or null when it cannot be read.
  Future<Uint8List?> thumbnail(GalleryPhoto photo, {int size = 240});

  /// The photo ready to send (long edge at most 1600 px, JPEG), or null when
  /// it cannot be read.
  Future<PickedImage?> load(GalleryPhoto photo);

  /// With limited access, lets the member add photos to what they allowed
  /// (Android 14+ system sheet).
  Future<void> selectMore();
}

import 'attachment.dart';

/// What "From an app" produced.
sealed class ExternalPickResult {}

/// The member picked one or more photos, each already in the shape a grid
/// photo is: ready to send or use as a picture.
final class ExternalPickedImages implements ExternalPickResult {
  const ExternalPickedImages(this.images, {this.dropped = 0});
  final List<PickedImage> images;

  /// How many more photos the chosen app offered beyond
  /// [ExternalPicker.maxAttachments] -- never opened or read, only counted.
  /// Always 0 for [ExternalPicker.pickProfilePicture], which only ever asks
  /// for one photo.
  final int dropped;
}

/// The member closed the chooser, or the other app, without picking
/// anything. Not a failure: nothing is sent, and no notice is shown.
final class ExternalPickCancelled implements ExternalPickResult {
  const ExternalPickCancelled();
}

/// What came back was not a readable photo: a non-image file, or a file
/// that could not be decoded.
final class ExternalPickFailed implements ExternalPickResult {
  const ExternalPickFailed();
}

/// Hands photo selection to another app on the phone (Google Photos, the
/// maker's gallery, Files...) through Android's own app chooser, or on iOS
/// through the system photo picker. Needs no photo permission: the chosen
/// app (or the picker) grants this app read access to only what the member
/// picked.
///
/// Its own boundary (like [Gallery]) because it is a platform capability;
/// [PickedImage]s it returns are in the exact same shape [Gallery.load] and
/// [Gallery.loadForCrop] return, so callers treat them identically.
abstract interface class ExternalPicker {
  /// The most [pickAttachments] ever returns in one pick. Anything the
  /// chosen app offers beyond this is dropped before it is opened or read
  /// (see [ExternalPickedImages.dropped]).
  static const maxAttachments = 10;

  /// Opens the chooser for one or more photos -- however many the chosen
  /// app allows -- each at the long-edge-1600 JPEG shape used for a chat
  /// attachment.
  Future<ExternalPickResult> pickAttachments();

  /// Opens the chooser for exactly one photo, returned uncropped and
  /// upright, ready for the crop screen -- the same shape [Gallery.loadForCrop]
  /// returns.
  Future<ExternalPickResult> pickProfilePicture();
}

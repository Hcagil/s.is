import 'dart:typed_data';

import 'gallery.dart';
import 'video.dart';

/// A video on the phone, by the platform's id; its picture is fetched on
/// demand.
final class GalleryVideo {
  /// Creates a gallery video.
  const GalleryVideo({required this.id, required this.durationMs});

  /// The platform's id for this video.
  final String id;

  /// Length in milliseconds.
  final int durationMs;
}

/// The phone's own videos, for the in-app video grid.
///
/// Its own boundary because reading the library needs the member's permission.
/// Never throws.
abstract interface class VideoGallery {
  /// Asks for permission the first time; afterwards answers without asking
  /// again.
  Future<GalleryAccess> requestAccess();

  /// A page of the newest videos the member allowed, newest first; empty
  /// once [page] is past the end (or without access). [page] is 0-based;
  /// each page holds up to [count] videos. A page shorter than [count]
  /// means there is no next page.
  Future<List<GalleryVideo>> recent({int page = 0, int count = 60});

  /// A small square-ish picture for the grid, or null when it cannot be read.
  Future<Uint8List?> thumbnail(GalleryVideo video, {int size = 240});

  /// With limited access, lets the member allow more videos (the system's
  /// own sheet).
  Future<void> selectMore();

  /// Opens this app's page in the phone's settings, for when access is
  /// [GalleryAccess.permanentlyDenied] and no prompt will be shown again.
  Future<void> openSettings();

  /// Copies each chosen video into the app's own folder, exactly as the
  /// phone-picker path does. Videos over maxVideoMs are only counted in
  /// [VideoPick.tooLong]; unreadable ones are skipped; an empty [VideoPick]
  /// on total failure.
  Future<VideoPick> prepare(List<GalleryVideo> chosen);
}

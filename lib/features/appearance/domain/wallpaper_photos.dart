/// What choosing a wallpaper picture produced.
sealed class WallpaperPick {
  const WallpaperPick();
}

/// The photo was copied into the app's own folder; [path] is that file.
final class WallpaperPicked extends WallpaperPick {
  const WallpaperPicked(this.path);
  final String path;
}

/// The member closed the chooser without picking. Not a failure.
final class WallpaperPickCancelled extends WallpaperPick {
  const WallpaperPickCancelled();
}

/// The chosen file could not be read or saved.
final class WallpaperPickFailed extends WallpaperPick {
  const WallpaperPickFailed();
}

/// Lets the member choose a photo from the phone and keeps a copy of it in
/// the app's own folder.
abstract interface class WallpaperPhotos {
  /// Opens the phone's photo chooser. Never throws.
  Future<WallpaperPick> pick();

  /// Deletes a copy made by [pick]. Never throws; a missing file is fine.
  Future<void> delete(String path);
}

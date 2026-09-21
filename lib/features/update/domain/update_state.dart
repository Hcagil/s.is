/// What the update feature wants the UI to do right now.
sealed class UpdateState {
  const UpdateState();
}

/// Nothing to do.
final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

/// Play offers a newer build; the user may take it or dismiss it.
final class UpdateAvailableFlexible extends UpdateState {
  const UpdateAvailableFlexible(this.versionCode);

  final int versionCode;
}

/// A flexible update is downloading in the background.
final class UpdateDownloading extends UpdateState {
  const UpdateDownloading();
}

/// The download finished; installing restarts the app.
final class UpdateReadyToInstall extends UpdateState {
  const UpdateReadyToInstall();
}

/// The installed build is below the server-side minimum; the app is blocked.
final class UpdateRequired extends UpdateState {
  const UpdateRequired({required this.installed, required this.minimum});

  final int installed;
  final int minimum;
}

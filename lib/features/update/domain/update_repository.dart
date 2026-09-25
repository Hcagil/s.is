import '../../../core/failure.dart';

/// Update policy and Play in-app update boundary.
abstract interface class UpdateRepository {
  /// The running build's versionCode.
  Future<int> installedBuild();

  /// The running build's version name, e.g. "0.6.0".
  Future<String> installedVersion();

  /// `app_config.min_supported_build`; an [Err] must never block the user.
  Future<Result<int>> minSupportedBuild();

  /// What Play currently knows about an update for this app: an offered
  /// build, an already-downloaded one, or neither. An [Err] must never
  /// block the user.
  Future<Result<PlayUpdateCheck>> checkForUpdate();

  Future<void> startFlexibleUpdate();

  Future<void> completeFlexibleUpdate();

  /// Immediate (blocking) update — used only below the minimum supported build.
  Future<void> startImmediateUpdate();

  /// Opens the Play listing; the fallback when an in-app update cannot start.
  Future<void> openStoreListing();
}

/// The result of asking Play about an update for this app.
class PlayUpdateCheck {
  const PlayUpdateCheck({this.offeredBuild, this.downloaded = false});

  /// A newer build Play offers as a flexible update; null when none is
  /// offered.
  final int? offeredBuild;

  /// A previously started flexible update finished downloading (possibly in
  /// an earlier app session) and is waiting for
  /// [UpdateRepository.completeFlexibleUpdate].
  final bool downloaded;
}

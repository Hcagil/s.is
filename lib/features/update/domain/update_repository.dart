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

  /// Opens the store listing (Play, or TestFlight on iPhone); the fallback when
  /// an in-app update cannot start. True when the launch succeeded; a thrown
  /// launch error is false.
  Future<bool> openStoreListing();
}

/// Play's per-release update priority (0-5) from which every member sees the flexible-update box; a lower one (a quiet release, docs/DELIVERY.md) is shown only to people with Admin Panels access.
const normalUpdatePriority = 2;

/// The result of asking Play about an update for this app.
class PlayUpdateCheck {
  const PlayUpdateCheck({
    this.offeredBuild,
    this.downloaded = false,
    this.updatePriority = normalUpdatePriority,
  });

  /// A newer build Play offers as a flexible update; null when none is
  /// offered.
  final int? offeredBuild;

  /// A previously started flexible update finished downloading (possibly in
  /// an earlier app session) and is waiting for
  /// [UpdateRepository.completeFlexibleUpdate].
  final bool downloaded;

  /// The priority Play reports for the offered build; meaningful only when
  /// [offeredBuild] is set.
  final int updatePriority;
}

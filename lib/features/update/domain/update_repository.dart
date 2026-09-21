import '../../../core/failure.dart';

/// Update policy and Play in-app update boundary.
abstract interface class UpdateRepository {
  /// The running build's versionCode.
  Future<int> installedBuild();

  /// `app_config.min_supported_build`; an [Err] must never block the user.
  Future<Result<int>> minSupportedBuild();

  /// The versionCode Play offers as a flexible update, or `null` when none.
  Future<Result<int?>> availablePlayBuild();

  Future<void> startFlexibleUpdate();

  Future<void> completeFlexibleUpdate();

  /// Immediate (blocking) update — used only below the minimum supported build.
  Future<void> startImmediateUpdate();

  /// Opens the Play listing; the fallback when an in-app update cannot start.
  Future<void> openStoreListing();
}

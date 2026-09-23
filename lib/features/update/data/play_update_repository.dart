import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/failure.dart';
import '../domain/update_repository.dart';

/// [UpdateRepository] backed by `app_config` and Google Play in-app updates.
final class PlayUpdateRepository implements UpdateRepository {
  PlayUpdateRepository(this._client);

  final SupabaseClient _client;

  static const _package = 'com.esd.sis';

  @override
  Future<int> installedBuild() async =>
      // An unparsable build number must never block anyone.
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? (1 << 30);

  @override
  Future<String> installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  @override
  Future<Result<int>> minSupportedBuild() async {
    try {
      final row = await _client
          .from('app_config')
          .select('min_supported_build')
          .eq('id', 1)
          .single();
      return Ok(row['min_supported_build'] as int);
    } on PostgrestException catch (e) {
      return Err(NetworkFailure(e.message));
    } catch (e) {
      return Err(NetworkFailure('$e'));
    }
  }

  @override
  Future<Result<int?>> availablePlayBuild() async {
    try {
      final info = await InAppUpdate.checkForUpdate();
      final offered =
          info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.flexibleUpdateAllowed;
      return Ok(offered ? info.availableVersionCode : null);
    } catch (e) {
      // Not installed from Play, or an unsupported platform: no update.
      return Err(NetworkFailure('$e'));
    }
  }

  @override
  Future<void> startFlexibleUpdate() => InAppUpdate.startFlexibleUpdate();

  @override
  Future<void> completeFlexibleUpdate() => InAppUpdate.completeFlexibleUpdate();

  @override
  Future<void> startImmediateUpdate() => InAppUpdate.performImmediateUpdate();

  @override
  Future<void> openStoreListing() async {
    const web = 'https://play.google.com/store/apps/details?id=$_package';
    try {
      final opened = await launchUrl(
        Uri.parse('market://details?id=$_package'),
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;
    } catch (_) {
      // No Play app to handle market://; fall through to the web listing.
    }
    await launchUrl(Uri.parse(web), mode: LaunchMode.externalApplication);
  }
}

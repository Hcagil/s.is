import 'package:in_app_update/in_app_update.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/update_repository.dart';
import 'app_config_update_policy.dart';

/// [UpdateRepository] backed by `app_config` and Google Play in-app updates.
final class PlayUpdateRepository
    with AppConfigUpdatePolicy
    implements UpdateRepository {
  PlayUpdateRepository(this.client);

  @override
  final SupabaseClient client;

  static const _package = 'com.esd.sis';

  @override
  Future<Result<PlayUpdateCheck>> checkForUpdate() async {
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.installStatus == InstallStatus.downloaded) {
        return Ok(const PlayUpdateCheck(downloaded: true));
      }
      final offered =
          info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.flexibleUpdateAllowed;
      return Ok(
        PlayUpdateCheck(
          offeredBuild: offered ? info.availableVersionCode : null,
        ),
      );
    } catch (e) {
      // Not installed from Play, or an unsupported platform: no update.
      return Err(readableFailure(e));
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

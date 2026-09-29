import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/failure.dart';
import '../domain/update_repository.dart';
import 'app_config_update_policy.dart';

/// iOS builds arrive via TestFlight, which notifies testers itself, so no
/// in-app update is ever offered and in_app_update (Play-only) is never
/// touched; the minimum-build policy is shared via AppConfigUpdatePolicy, not inherited.
final class TestFlightUpdateRepository
    with AppConfigUpdatePolicy
    implements UpdateRepository {
  TestFlightUpdateRepository(this.client);

  @override
  final SupabaseClient client;

  @override
  Future<Result<PlayUpdateCheck>> checkForUpdate() async =>
      Ok(const PlayUpdateCheck());

  @override
  Future<void> startFlexibleUpdate() async {}

  @override
  Future<void> completeFlexibleUpdate() async {}

  @override
  Future<void> startImmediateUpdate() => openStoreListing();

  @override
  Future<void> openStoreListing() async {
    // ponytail: TestFlight link; becomes the App Store URL at App Store
    // release.
    await launchUrl(
      Uri.parse('itms-beta://'),
      mode: LaunchMode.externalApplication,
    );
  }
}

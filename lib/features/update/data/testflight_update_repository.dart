import 'package:url_launcher/url_launcher.dart';

import '../../../core/failure.dart';
import '../domain/update_repository.dart';
import 'play_update_repository.dart';

/// iOS builds arrive via TestFlight, which notifies testers itself, so no
/// in-app update is ever offered and in_app_update (Play-only) is never
/// touched; the minimum-build policy and build-number reading are inherited.
final class TestFlightUpdateRepository extends PlayUpdateRepository {
  TestFlightUpdateRepository(super.client);

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

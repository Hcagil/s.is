import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/update_repository.dart';

/// The update policy shared by every platform: the running build from
/// PackageInfo and the minimum from app_config.
mixin AppConfigUpdatePolicy implements UpdateRepository {
  SupabaseClient get client;

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
      final row = await client
          .from('app_config')
          .select('min_supported_build')
          .eq('id', 1)
          .single()
          .retriedOnce();
      return Ok(row['min_supported_build'] as int);
    } catch (e) {
      return Err(readableFailure(e));
    }
  }
}

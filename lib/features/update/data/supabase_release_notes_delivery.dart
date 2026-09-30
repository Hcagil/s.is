import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/release_notes.dart';

/// [ReleaseNotesDelivery] over the `deliver_release_notes` RPC, remembering
/// per member on this device the highest build already served.
final class SupabaseReleaseNotesDelivery implements ReleaseNotesDelivery {
  SupabaseReleaseNotesDelivery(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<bool>> deliver(String userId) async {
    try {
      final build = int.tryParse(
        (await PackageInfo.fromPlatform()).buildNumber,
      );
      if (build == null) return const Ok(false);

      final key = 'release_notes_served_build_$userId';
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getInt(key) ?? 0) >= build) return const Ok(false);

      await _client.rpc(
        'deliver_release_notes',
        params: {'installed_build': build},
      );
      await prefs.setInt(key, build);
      return const Ok(true);
    } on PostgrestException catch (e) {
      if (e.code == '42501') return const Err(DeniedFailure());
      return Err(readableFailure(e));
    } catch (e) {
      return Err(readableFailure(e));
    }
  }
}

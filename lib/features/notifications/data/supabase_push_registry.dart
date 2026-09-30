import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/push.dart';

/// The server's delivery list; a refused call (no app access) is DeniedFailure.
final class SupabasePushRegistry implements PushRegistry {
  SupabasePushRegistry(this._client, {this.platform = 'android'});

  final SupabaseClient _client;

  /// 'android' or 'ios': stored with the token, so the server sends the
  /// payload that platform can show.
  final String platform;

  @override
  Future<Result<void>> register(String token) async {
    try {
      await _client.rpc(
        'register_device_token',
        params: {
          'device_token': token,
          'device_platform': platform,
          // Android draws pushes itself, grouped: send it data only. An
          // iPhone is shown a regular notification by the system.
          'shows_itself': platform == 'android',
        },
      );
      return const Ok(null);
    } on PostgrestException catch (e) {
      if (e.code == '42501') return const Err(DeniedFailure());
      return Err(readableFailure(e));
    } catch (e) {
      return Err(readableFailure(e));
    }
  }

  @override
  Future<Result<void>> forget(String token) async {
    try {
      await _client.rpc('forget_device_token', params: {'device_token': token});
      return const Ok(null);
    } on PostgrestException catch (e) {
      if (e.code == '42501') return const Err(DeniedFailure());
      return Err(readableFailure(e));
    } catch (e) {
      return Err(readableFailure(e));
    }
  }
}

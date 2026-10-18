import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/key_directory.dart';

/// [KeyDirectory] backed by Supabase RPCs.
final class SupabaseKeyDirectory implements KeyDirectory {
  SupabaseKeyDirectory(this._client);

  final SupabaseClient _client;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == 'RLMT1' =>
      const SearchLimitFailure(),
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<int>> publish({
    required String identityKey,
    required String signingKey,
    required String deviceSignature,
    required List<String> oneTimeKeys,
    String? fallbackKey,
  }) async {
    try {
      final res = await _client.rpc(
        'publish_olm_keys',
        params: {
          'p_identity_key': identityKey,
          'p_signing_key': signingKey,
          'p_device_signature': deviceSignature,
          'p_one_time_keys': oneTimeKeys,
          'p_fallback_key': fallbackKey,
        },
      );
      return Ok(res as int);
    } on PostgrestException catch (e) {
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<ClaimedKeys?>> claim(String userId) async {
    try {
      final res = await _client.rpc(
        'claim_olm_keys',
        params: {'target': userId},
      ) as List<dynamic>;
      if (res.isEmpty) return const Ok(null);
      final r = res[0] as Map<String, dynamic>;
      return Ok(
        ClaimedKeys(
          identityKey: r['identity_key'] as String,
          signingKey: r['signing_key'] as String,
          deviceSignature: r['device_signature'] as String,
          oneTimeKey: r['one_time_key'] as String,
          isFallback: r['is_fallback'] as bool,
        ),
      );
    } on PostgrestException catch (e) {
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<PublishedStatus?>> status() async {
    try {
      final res = await _client.rpc('olm_key_status') as List<dynamic>;
      if (res.isEmpty) return const Ok(null);
      final r = res[0] as Map<String, dynamic>;
      return Ok(
        PublishedStatus(
          identityKey: r['identity_key'] as String,
          signingKey: r['signing_key'] as String,
          oneTimeKeys: r['one_time_keys'] as int,
          hasFallback: r['has_fallback'] as bool,
          fallbackUsed: r['fallback_used'] as bool,
          sameSession: r['same_session'] as bool,
        ),
      );
    } on PostgrestException catch (e) {
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

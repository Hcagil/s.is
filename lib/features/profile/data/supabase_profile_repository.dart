import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/own_profile.dart';
import '../domain/profile_repository.dart';

/// [ProfileRepository] backed by `public.profiles`.
final class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final SupabaseClient _client;

  static const _columns =
      'user_id, display_name, tag, onboarding_done, share_presence, share_typing, share_last_seen, share_read_status';

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '23505' =>
      const ProviderFailure('That tag was just taken. Pick another.'),
    PostgrestException(:final code) when code == '23514' =>
      const ProviderFailure('That name or tag is not allowed.'),
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  OwnProfile _toProfile(Map<String, dynamic> row) => OwnProfile(
    userId: row['user_id'] as String,
    displayName: row['display_name'] as String,
    tag: row['tag'] as String,
    onboardingDone: row['onboarding_done'] as bool,
    sharePresence: row['share_presence'] as bool,
    shareTyping: row['share_typing'] as bool,
    shareLastSeen: row['share_last_seen'] as bool,
    shareReadStatus: row['share_read_status'] as bool,
  );

  @override
  Future<Result<OwnProfile>> load() async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    try {
      final row = await _client
          .from('profiles')
          .select(_columns)
          .eq('user_id', me)
          .single();
      return Ok(_toProfile(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<OwnProfile>> save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
    bool? sharePresence,
    bool? shareTyping,
    bool? shareLastSeen,
    bool? shareReadStatus,
  }) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    final changes = <String, Object>{
      'display_name': ?displayName?.trim(),
      if (tag != null) 'tag': normaliseTag(tag),
      'onboarding_done': ?onboardingDone,
      'share_presence': ?sharePresence,
      'share_typing': ?shareTyping,
      'share_last_seen': ?shareLastSeen,
      'share_read_status': ?shareReadStatus,
    };
    if (changes.isEmpty) return load();
    try {
      final row = await _client
          .from('profiles')
          .update(changes)
          .eq('user_id', me)
          .select(_columns)
          .single();
      return Ok(_toProfile(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<bool>> isTagAvailable(String tag) async {
    try {
      final free = await _client.rpc(
        'is_tag_available',
        params: {'candidate': normaliseTag(tag)},
      );
      return Ok(free == true);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

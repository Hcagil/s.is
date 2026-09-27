import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../../chat/domain/attachment.dart';
import '../domain/own_profile.dart';
import '../domain/profile_repository.dart';

/// [ProfileRepository] backed by `public.profiles`.
final class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final SupabaseClient _client;

  static const _columns =
      'user_id, display_name, tag, onboarding_done, share_presence, share_typing, share_last_seen, share_read_status, avatar_path';

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
    avatarPath: row['avatar_path'] as String?,
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
          .single()
          .retriedOnce();
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
  Future<Result<OwnProfile>> setAvatar(
    PickedImage image, {
    String? previousPath,
  }) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    // Set once the upload actually succeeds, so a failed upload is never
    // "cleaned up" (there is nothing there to clean up).
    String? uploaded;
    try {
      final path =
          'profile/$me/${DateTime.now().microsecondsSinceEpoch}.${image.extension}';
      await _client.storage
          .from('avatars')
          .uploadBinary(
            path,
            image.bytes,
            fileOptions: FileOptions(contentType: image.contentType),
          );
      uploaded = path;
      final row = await _client
          .from('profiles')
          .update({'avatar_path': path})
          .eq('user_id', me)
          .select(_columns)
          .single();
      if (previousPath != null) {
        try {
          await _client.storage.from('avatars').remove([previousPath]);
        } catch (_) {
          // Best-effort: the reference is already gone; an orphaned object
          // costs storage, not correctness.
        }
      }
      return Ok(_toProfile(row));
    } on PostgrestException catch (e) {
      // The server ran and definitely refused (RLS, a constraint, or the
      // update matching no row): the transaction rolled back, so the upload
      // (if any) went up but the row never pointed at it, and it is safe to
      // remove now.
      if (uploaded != null) {
        try {
          await _client.storage.from('avatars').remove([uploaded]);
        } catch (_) {}
      }
      return Err(_asFailure(e));
    } catch (e) {
      // Unreachable server, a dropped connection, a timeout: the update may
      // have committed and only the reply was lost. Deleting here could
      // delete the picture the row now actually points to -- worse than
      // leaving a possible orphan behind, so this never cleans up.
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<OwnProfile>> removeAvatar(String previousPath) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    try {
      final row = await _client
          .from('profiles')
          .update({'avatar_path': null})
          .eq('user_id', me)
          .select(_columns)
          .single();
      try {
        await _client.storage.from('avatars').remove([previousPath]);
      } catch (_) {
        // Best-effort, as above.
      }
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

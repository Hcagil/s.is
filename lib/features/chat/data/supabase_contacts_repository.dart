import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../../auth/domain/member.dart';
import '../domain/contacts_repository.dart';

/// [ContactsRepository] backed by `public.contacts`.
final class SupabaseContactsRepository implements ContactsRepository {
  SupabaseContactsRepository(this._client);

  final SupabaseClient _client;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == 'RLMT1' =>
      const ProviderFailure('Too many searches, try again later.'),
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<Member?>> findByTag(String tag) async {
    try {
      final rows = await _client.rpc(
        'find_by_tag',
        params: {'search_tag': tag},
      ) as List<dynamic>;
      if (rows.isEmpty) return const Ok(null);
      final row = rows[0] as Map<String, dynamic>;
      return Ok(
        Member(
          userId: row['user_id'] as String,
          displayName: row['display_name'] as String,
          tag: row['tag'] as String?,
          avatarPath: row['avatar_path'] as String?,
        ),
      );
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> add(String userId) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    try {
      await _client.from('contacts').insert({
        'owner_id': me,
        'contact_id': userId,
      });
      return const Ok(null);
    } on PostgrestException catch (e) {
      // Primary key violation: already a contact. Idempotent.
      if (e.code == '23505') return const Ok(null);
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> remove(String userId) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    try {
      await _client
          .from('contacts')
          .delete()
          .eq('owner_id', me)
          .eq('contact_id', userId);
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Set<String>>> ids() async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    try {
      final rows = await _client
          .from('contacts')
          .select('contact_id')
          .eq('owner_id', me)
          .retriedOnce();
      return Ok({for (final r in rows) r['contact_id'] as String});
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

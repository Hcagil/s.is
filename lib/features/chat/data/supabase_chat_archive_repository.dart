import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/chat_archive_repository.dart';

/// [ChatArchiveRepository] backed by the `chat_archives` table. Row-level
/// security lets a member write only their own rows, and only for a
/// conversation they belong or belonged to.
final class SupabaseChatArchiveRepository implements ChatArchiveRepository {
  SupabaseChatArchiveRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<void>> setArchived(String conversationId, bool archived) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      if (archived) {
        await _client
            .from('chat_archives')
            .upsert(
              {'user_id': uid, 'conversation_id': conversationId},
              onConflict: 'user_id,conversation_id',
              ignoreDuplicates: true,
            );
      } else {
        await _client
            .from('chat_archives')
            .delete()
            .eq('user_id', uid)
            .eq('conversation_id', conversationId);
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

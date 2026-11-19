import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/chat_mark_repository.dart';

/// [ChatMarkRepository] backed by the function `mark_chat_unread`.
final class SupabaseChatMarkRepository implements ChatMarkRepository {
  SupabaseChatMarkRepository(this._client);

  final SupabaseClient _client;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<void>> markChatUnread(String conversationId) async {
    try {
      await _client.rpc(
        'mark_chat_unread',
        params: {'conversation': conversationId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

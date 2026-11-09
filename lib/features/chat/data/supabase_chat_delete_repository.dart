import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/chat_delete_repository.dart';

/// [ChatDeleteRepository] backed by the `hide_chat` function. The server
/// checks who may call it.
final class SupabaseChatDeleteRepository implements ChatDeleteRepository {
  SupabaseChatDeleteRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<void>> hideChat(String conversationId) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      await _client.rpc('hide_chat', params: {'conversation': conversationId});
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

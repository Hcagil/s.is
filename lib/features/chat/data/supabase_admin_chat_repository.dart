import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/admin_chat_repository.dart';

/// [AdminChatRepository] backed by the admin_answer RPC; the server checks the owner.
class SupabaseAdminChatRepository implements AdminChatRepository {
  SupabaseAdminChatRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Result<void>> answer(String cardId, bool yes) async {
    try {
      await _client.rpc('admin_answer', params: {'card': cardId, 'yes': yes});
      return const Ok(null);
    } on PostgrestException catch (e) {
      return Err(
        e.code == '42501' ? const DeniedFailure() : readableFailure(e),
      );
    } catch (e) {
      return Err(readableFailure(e));
    }
  }
}

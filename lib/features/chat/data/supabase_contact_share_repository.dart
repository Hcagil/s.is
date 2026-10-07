import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/contact_share_repository.dart';
import '../domain/shared_contact.dart';

/// [ContactShareRepository] backed by the send_contact function: the only write path for a contact message; the server refuses (42501) a caller who may not post in the conversation.
final class SupabaseContactShareRepository implements ContactShareRepository {
  SupabaseContactShareRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    SharedContact contact,
  ) async {
    try {
      await _client.rpc(
        'send_contact',
        params: {
          'p_conversation': conversationId,
          'p_id': messageId,
          'p_name': contact.name,
          'p_phone': contact.phone,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(switch (e) {
        PostgrestException(:final code) when code == '42501' =>
          const DeniedFailure(),
        _ => readableFailure(e),
      });
    }
  }
}

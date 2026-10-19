import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/encrypted_message_repository.dart';
import '../domain/message.dart';

/// [EncryptedMessageRepository] over the messages table and the edit_message_encrypted function.
final class SupabaseEncryptedMessageRepository
    implements EncryptedMessageRepository {
  SupabaseEncryptedMessageRepository(this._client);

  final SupabaseClient _client;

  static const _columns =
      'id, conversation_id, sender_id, body, created_at, reply_to, forwarded, edited_at';

  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String ciphertext,
    required int olmType,
    String? replyTo,
    bool forwarded = false,
  }) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());
    try {
      final row = await _client
          .from('messages')
          .insert({
            'id': id,
            'conversation_id': conversationId,
            'sender_id': me,
            'body': lockedBodyPlaceholder,
            'ciphertext': ciphertext,
            'olm_type': olmType,
            'reply_to': ?replyTo,
            if (forwarded) 'forwarded': true,
          })
          .select(_columns)
          .single();
      return Ok(_toMessage(row));
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // This id is already stored: an earlier attempt reached the server but its answer was lost. Accept it as ours only when the ciphertext is identical, never on trust.
        try {
          final row = await _client
              .from('messages')
              .select('$_columns, ciphertext')
              .eq('id', id)
              .maybeSingle()
              .retriedOnce();
          if (row == null) return const Err(DeniedFailure());
          final ours =
              row['sender_id'] == me &&
              row['conversation_id'] == conversationId &&
              row['ciphertext'] == ciphertext &&
              (replyTo == null || row['reply_to'] == replyTo);
          if (!ours) return const Err(DeniedFailure());
          return Ok(_toMessage(row));
        } catch (e2) {
          return Err(_asFailure(e2));
        }
      }
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message>> edit({
    required String id,
    required String ciphertext,
    required int olmType,
  }) async {
    try {
      final row = await _client.rpc(
        'edit_message_encrypted',
        params: {'p_id': id, 'p_ciphertext': ciphertext, 'p_olm_type': olmType},
      );
      return Ok(_toMessage(row as Map<String, dynamic>));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  Failure _asFailure(Object e) {
    if (e is PostgrestException && (e.code == '42501' || e.code == 'ENCR1')) {
      return const DeniedFailure();
    }
    return readableFailure(e);
  }

  Message _toMessage(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      senderId: row['sender_id'] as String,
      body: row['body'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      replyTo: row['reply_to'] as String?,
      forwarded: row['forwarded'] as bool? ?? false,
      editedAt: row['edited_at'] == null
          ? null
          : DateTime.parse(row['edited_at'] as String).toLocal(),
    );
  }
}

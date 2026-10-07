import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/chat_pin_repository.dart';
import '../domain/group_event.dart';
import '../domain/message.dart';

/// [ChatPinRepository] backed by the `chat_pins` table (own rows only; the
/// 5-pin limit is enforced by the database) and the functions
/// `set_pinned_message`, `set_members_can_pin` and `pin_events`.
final class SupabaseChatPinRepository implements ChatPinRepository {
  SupabaseChatPinRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '54000' =>
      const PinLimitFailure(),
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<void>> setChatPinned(String conversationId, bool pinned) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      if (pinned) {
        await _client
            .from('chat_pins')
            .upsert(
              {'user_id': uid, 'conversation_id': conversationId},
              onConflict: 'user_id,conversation_id',
              ignoreDuplicates: true,
            );
      } else {
        await _client
            .from('chat_pins')
            .delete()
            .eq('user_id', uid)
            .eq('conversation_id', conversationId);
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> setPinnedMessage(
    String conversationId,
    String? messageId,
  ) async {
    try {
      await _client.rpc(
        'set_pinned_message',
        params: {'conversation': conversationId, 'message': messageId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> setMembersCanPin(
    String conversationId,
    bool allowed,
  ) async {
    try {
      await _client.rpc(
        'set_members_can_pin',
        params: {'conversation': conversationId, 'allowed': allowed},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<GroupEvent>>> pinEvents(String conversationId) async {
    try {
      final rows = await _client.rpc(
        'pin_events',
        params: {'conversation': conversationId},
      );
      return Ok([
        for (final row in (rows as List).cast<Map<String, dynamic>>())
          GroupEvent(
            id: row['id'] as String,
            conversationId: row['conversation_id'] as String,
            kind: GroupEventKind.pinned,
            subjectId: (row['actor_id'] as String?) ?? '',
            actorId: row['actor_id'] as String?,
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message?>> pinnedMessage(
    String conversationId,
    String messageId,
  ) async {
    try {
      // Row-level security decides what comes back: a message outside the
      // caller's readable window, or one they hid, is simply absent.
      final rows = await _client
          .from('messages')
          .select(
            'id, conversation_id, sender_id, body, created_at, '
            'attachment_path, deleted',
          )
          .eq('id', messageId)
          .eq('conversation_id', conversationId)
          .retriedOnce();
      if (rows.isEmpty || rows.first['deleted'] != null) {
        return const Ok(null);
      }
      final row = rows.first;
      return Ok(
        Message(
          id: row['id'] as String,
          conversationId: row['conversation_id'] as String,
          senderId: row['sender_id'] as String,
          body: row['body'] as String,
          createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
          attachmentPath: row['attachment_path'] as String?,
        ),
      );
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

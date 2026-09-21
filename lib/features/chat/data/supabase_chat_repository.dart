import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

/// [ChatRepository] backed by Supabase Postgres and Realtime.
///
/// Row-level security decides what any of these queries return; nothing here
/// filters for authorisation. A refusal arrives as a [PostgrestException] with
/// SQLSTATE 42501 and is reported as [DeniedFailure].
final class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client);

  final SupabaseClient _client;

  /// How far back the conversation list looks for previews in one query.
  // ponytail: a single bounded read instead of one query per conversation.
  // If a member ever has more conversations than this covers, move the preview
  // into a view or an RPC with DISTINCT ON rather than raising the number.
  static const _previewScan = 200;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    PostgrestException(:final message) => NetworkFailure(message),
    _ => NetworkFailure('$e'),
  };

  @override
  Future<Result<List<Conversation>>> conversations() async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    try {
      // RLS returns membership rows only for conversations this member belongs
      // to, so this is already scoped — including the other side's row.
      final memberRows = await _client
          .from('conversation_members')
          .select('conversation_id, user_id');

      final otherByConversation = <String, String>{};
      for (final row in memberRows) {
        final userId = row['user_id'] as String;
        if (userId == me) continue;
        otherByConversation[row['conversation_id'] as String] = userId;
      }
      if (otherByConversation.isEmpty) return const Ok([]);

      final profileRows = await _client
          .from('profiles')
          .select('user_id, display_name')
          .inFilter('user_id', otherByConversation.values.toSet().toList());
      final nameByUser = {
        for (final row in profileRows)
          row['user_id'] as String: row['display_name'] as String,
      };

      // Newest first, so the first row seen for a conversation is its preview.
      final recent = await _client
          .from('messages')
          .select('conversation_id, body, created_at')
          .order('created_at', ascending: false)
          .limit(_previewScan);
      final previewBy = <String, ({String body, DateTime at})>{};
      for (final row in recent) {
        previewBy.putIfAbsent(
          row['conversation_id'] as String,
          () => (
            body: row['body'] as String,
            at: DateTime.parse(row['created_at'] as String),
          ),
        );
      }

      final conversations = [
        for (final entry in otherByConversation.entries)
          Conversation(
            id: entry.key,
            other: Member(
              userId: entry.value,
              displayName: nameByUser[entry.value] ?? 'Member',
            ),
            lastMessage: previewBy[entry.key]?.body,
            lastMessageAt: previewBy[entry.key]?.at,
          ),
      ];
      // Conversations with no messages yet sort last.
      conversations.sort((a, b) {
        final at = a.lastMessageAt, bt = b.lastMessageAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      return Ok(conversations);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    try {
      final rows = await _client
          .from('messages')
          .select('id, conversation_id, sender_id, body, created_at')
          .eq('conversation_id', conversationId)
          .order('created_at');
      return Ok(rows.map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> send({
    required String conversationId,
    required String body,
  }) async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    final trimmed = body.trim();
    if (!isSendableBody(trimmed)) {
      return const Err(DeniedFailure());
    }
    try {
      // id and created_at are withheld by the column-level grant; the server
      // assigns both.
      await _client.from('messages').insert({
        'conversation_id': conversationId,
        'sender_id': me,
        'body': trimmed,
      });
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Stream<Message>> incoming(String conversationId) async {
    final channel = _client.channel('messages:$conversationId');
    final controller = StreamController<Message>();
    final subscribed = Completer<void>();

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) {
            if (controller.isClosed) return;
            controller.add(_toMessage(payload.newRecord));
          },
        )
        .subscribe((status, error) {
          if (subscribed.isCompleted) return;
          if (status == RealtimeSubscribeStatus.subscribed) {
            subscribed.complete();
          } else if (error != null) {
            subscribed.completeError(error);
          }
        });
    controller.onCancel = () async => _client.removeChannel(channel);

    // A dead subscription must fail loudly rather than hang the screen.
    await subscribed.future.timeout(const Duration(seconds: 15));
    // The controller buffers anything that lands before the caller listens.
    return controller.stream;
  }

  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async {
    try {
      final id = await _client.rpc(
        'start_direct_conversation',
        params: {'other_user': otherUserId},
      );
      if (id is! String) {
        return const Err(DeniedFailure());
      }
      return Ok(id);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  Message _toMessage(Map<String, dynamic> row) => Message(
    id: row['id'] as String,
    conversationId: row['conversation_id'] as String,
    senderId: row['sender_id'] as String,
    body: row['body'] as String,
    createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
  );
}

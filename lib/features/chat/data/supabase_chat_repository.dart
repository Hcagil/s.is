import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import '../domain/attachment.dart';
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
  Future<Result<List<Member>>> members() async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    try {
      // profiles is readable by any active member; RLS keeps it to the group.
      final rows = await _client
          .from('profiles')
          .select('user_id, display_name')
          .neq('user_id', me)
          .order('display_name');
      return Ok([
        for (final row in rows)
          Member(
            userId: row['user_id'] as String,
            displayName: row['display_name'] as String,
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

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

      // Titles distinguish a group from a 1:1; RLS scopes this to the
      // caller's own conversations, same as the membership rows.
      final conversationRows = await _client
          .from('conversations')
          .select('id, title');
      final titleById = {
        for (final row in conversationRows)
          row['id'] as String: row['title'] as String?,
      };

      final otherByConversation = <String, String>{};
      for (final row in memberRows) {
        final userId = row['user_id'] as String;
        if (userId == me) continue;
        otherByConversation[row['conversation_id'] as String] = userId;
      }
      // A group is listed by its title, so it needs no "other" member; only
      // 1:1 conversations do.
      final conversationIds = {...titleById.keys, ...otherByConversation.keys};
      if (conversationIds.isEmpty) return const Ok([]);

      final others = otherByConversation.values.toSet().toList();
      final profileRows = others.isEmpty
          ? const <Map<String, dynamic>>[]
          : await _client
                .from('profiles')
                .select('user_id, display_name')
                .inFilter('user_id', others);
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
        for (final id in conversationIds)
          Conversation(
            id: id,
            title: titleById[id],
            other: titleById[id] != null || otherByConversation[id] == null
                ? null
                : Member(
                    userId: otherByConversation[id]!,
                    displayName:
                        nameByUser[otherByConversation[id]!] ?? 'Member',
                  ),
            lastMessage: previewBy[id]?.body,
            lastMessageAt: previewBy[id]?.at,
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
          .select(
            'id, conversation_id, sender_id, body, created_at, attachment_path',
          )
          .eq('conversation_id', conversationId)
          // ascending is EXPLICIT: postgrest-dart's `order` defaults to
          // descending, so the bare call returned newest-first while this
          // method documents oldest-first.
          .order('created_at', ascending: true);
      return Ok(rows.map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message>> send({
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
      // assigns both, and returns the row so the caller need not wait for the
      // Realtime echo to display it.
      final row = await _client
          .from('messages')
          .insert({
            'conversation_id': conversationId,
            'sender_id': me,
            'body': trimmed,
          })
          .select(
            'id, conversation_id, sender_id, body, created_at, attachment_path',
          )
          .single();
      return Ok(_toMessage(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
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

    try {
      // A dead subscription must fail loudly rather than hang the screen.
      await subscribed.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      // An unreachable server throws an SDK type (WebSocketChannelException,
      // SocketException, TimeoutException). Left unmapped it would be printed
      // on screen verbatim.
      //
      // Tear down WITHOUT awaiting: removeChannel sends an unsubscribe over
      // the same dead socket and waits for a reply that never arrives, so
      // awaiting it here would hang the very failure path that exists to stop
      // the screen hanging.
      unawaited(() async {
        try {
          await controller.close();
        } catch (_) {}
        try {
          await _client.removeChannel(channel);
        } catch (_) {}
      }());
      return Err(_asFailure(e));
    }
    // The controller buffers anything that lands before the caller listens.
    return Ok(controller.stream);
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

  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async {
    try {
      final id = await _client.rpc(
        'start_group_conversation',
        params: {'title': title.trim(), 'members': memberIds},
      );
      if (id is! String) return const Err(DeniedFailure());
      return Ok(id);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> setDisplayName(String displayName) async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    final trimmed = displayName.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      return const Err(DeniedFailure());
    }
    try {
      // Only display_name is grantable on this table, so nothing else on the
      // row can be rewritten even if this call asked to.
      await _client
          .from('profiles')
          .update({'display_name': trimmed})
          .eq('user_id', me);
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
  }) async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    try {
      // The conversation id is the FIRST path segment on purpose: the storage
      // policy reads it back and asks the same membership question the table
      // policies ask, instead of inventing a second rule that could drift.
      final path =
          '$conversationId/${DateTime.now().microsecondsSinceEpoch}'
          '-${me.substring(0, 8)}.${image.extension}';
      await _client.storage
          .from('attachments')
          .uploadBinary(
            path,
            image.bytes,
            fileOptions: FileOptions(contentType: image.contentType),
          );

      final row = await _client
          .from('messages')
          .insert({
            'conversation_id': conversationId,
            'sender_id': me,
            'body': body.trim(),
            'attachment_path': path,
          })
          .select(
            'id, conversation_id, sender_id, body, created_at, attachment_path',
          )
          .single();
      return Ok(_toMessage(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Uri>> attachmentUrl(String attachmentPath) async {
    try {
      final signed = await _client.storage
          .from('attachments')
          .createSignedUrl(attachmentPath, 3600);
      return Ok(Uri.parse(signed));
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
    attachmentPath: row['attachment_path'] as String?,
  );
}

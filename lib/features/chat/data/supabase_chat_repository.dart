import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/realtime_channels.dart';
import '../../auth/domain/member.dart';
import '../domain/attachment.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';

/// [ChatRepository] backed by Supabase Postgres and Realtime.
///
/// Row-level security decides what any of these queries return; nothing here
/// filters for authorisation. A refusal arrives as a [PostgrestException] with
/// SQLSTATE 42501 and is reported as [DeniedFailure].
final class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client, {AttachmentCache? cache})
    : _cache = cache ?? const _NoCache();

  final SupabaseClient _client;
  final AttachmentCache _cache;

  /// How many messages one conversation screen holds.
  static const _historyLimit = 500;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    // Storage refuses a non-member and reports a missing object alike; both
    // mean "not yours to see" or "gone", never raw SDK text on screen.
    StorageException(:final statusCode)
        when statusCode == '401' || statusCode == '403' =>
      const DeniedFailure(),
    StorageException() => const NetworkFailure('This photo is not available.'),
    _ => readableFailure(e),
  };

  @override
  Future<Result<List<Member>>> members() async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    try {
      // profiles is readable by any active member; RLS keeps it to the group.
      final rows = await _client
          .from('profiles')
          .select('user_id, display_name, tag')
          .neq('user_id', me)
          .order('display_name');
      return Ok([
        for (final row in rows)
          Member(
            userId: row['user_id'] as String,
            displayName: row['display_name'] as String,
            tag: row['tag'] as String?,
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
      // One row per conversation, from a view that does the DISTINCT ON in the
      // database. A bounded scan across all conversations used to lose the
      // preview of a quiet one as soon as enough newer messages existed
      // elsewhere, which rendered as "No messages yet" on a conversation that
      // had messages.
      final recent = await _client
          .from('conversation_previews')
          .select(
            'conversation_id, body, created_at, attachment_path, sender_id, deleted',
          );
      final previewBy = <String, ({String body, DateTime at, String sender})>{
        for (final row in recent)
          row['conversation_id'] as String: (
            // An image may be sent without a caption, and an empty preview
            // would read as "no messages" while hiding a real one.
            body: row['deleted'] != null
                ? 'This message was deleted'
                : (row['body'] as String).isNotEmpty
                ? row['body'] as String
                : (row['attachment_path'] == null ? '' : 'Photo'),
            at: DateTime.parse(row['created_at'] as String),
            sender: row['sender_id'] as String,
          ),
      };

      // Only conversations with something unread come back.
      final unreadRows = await _client.rpc('unread_counts') as List<dynamic>;
      final unreadBy = {
        for (final row in unreadRows.cast<Map<String, dynamic>>())
          row['conversation_id'] as String: row['unread'] as int,
      };

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
            lastSenderId: previewBy[id]?.sender,
            unread: unreadBy[id] ?? 0,
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

  static const _messageColumns =
      'id, conversation_id, sender_id, body, created_at, attachment_path, attachment_preview, deleted, reply_to, forwarded';

  @override
  Future<Result<List<Member>>> conversationMembers(
    String conversationId,
  ) async {
    try {
      // RLS returns these rows only to a member of the conversation.
      final rows = await _client
          .from('conversation_members')
          .select('user_id')
          .eq('conversation_id', conversationId);
      final ids = [for (final r in rows) r['user_id'] as String];
      if (ids.isEmpty) return const Ok([]);
      final profiles = await _client
          .from('profiles')
          .select('user_id, display_name, tag')
          .inFilter('user_id', ids)
          .order('display_name', ascending: true);
      return Ok([
        for (final p in profiles)
          Member(
            userId: p['user_id'] as String,
            displayName: p['display_name'] as String,
            tag: p['tag'] as String?,
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Message>>> sharedMedia(String conversationId) async {
    try {
      final rows = await _client
          .from('messages')
          .select(_messageColumns)
          .eq('conversation_id', conversationId)
          .not('attachment_path', 'is', null)
          // Newest first with a cap: what is lost is the oldest.
          .order('created_at', ascending: false)
          .limit(_historyLimit);
      return Ok(rows.map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Message>>> sharedLinks(String conversationId) async {
    try {
      // A coarse filter in the database; linkSegments decides what a link is.
      final rows = await _client
          .from('messages')
          .select(_messageColumns)
          .eq('conversation_id', conversationId)
          .or('body.ilike.*http://*,body.ilike.*https://*,body.ilike.*www.*')
          .order('created_at', ascending: false)
          .limit(_historyLimit);
      return Ok(rows.map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> markRead(String conversationId) async {
    try {
      await _client.rpc('mark_read', params: {'conversation': conversationId});
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    try {
      final rows = await _client
          .from('messages')
          .select(_messageColumns)
          .eq('conversation_id', conversationId)
          // Read NEWEST-first with a cap, then reverse. PostgREST truncates a
          // response at max_rows, and an ascending read would silently drop
          // the most recent messages -- a conversation frozen in the past,
          // which reads as working. Dropping the oldest is the honest
          // truncation.
          .order('created_at', ascending: false)
          .limit(_historyLimit);
      // The interface documents oldest-first, which is also what the screen
      // renders.
      // ponytail: one bounded page. If a conversation outgrows it, add
      // backward paging keyed on created_at rather than raising the cap.
      return Ok(rows.reversed.map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
    String? replyTo,
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
            'reply_to': ?replyTo,
          })
          .select(_messageColumns)
          .single();
      return Ok(_toMessage(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) => _inserts(
    'messages:$conversationId',
    PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    ),
  );

  @override
  Future<Result<Stream<Message>>> incomingAll() =>
      _inserts('messages:all', null);

  /// Subscribes to message inserts on [topic], optionally narrowed by
  /// [filter]. Without a filter every insert the caller may SELECT arrives:
  /// Realtime re-checks the read policy per subscriber.
  Future<Result<Stream<Message>>> _inserts(
    String topic,
    PostgresChangeFilter? filter,
  ) async {
    final channel = _client.channel(topic);
    final controller = StreamController<Message>();

    // Inserts are new messages; updates are deletions for everyone, which
    // arrive as the wiped row.
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'messages',
      filter: filter,
      callback: (payload) {
        if (controller.isClosed) return;
        final row = payload.newRecord;
        // An event the server could not authorise (a channel still open
        // after its account signed out) carries no row: there is nothing
        // to show, and a throw here would escape the Realtime client.
        if (row['id'] == null) return;
        controller.add(_toMessage(row));
      },
    );
    controller.onCancel = () => leaveChannel(_client, channel);

    try {
      // A dead subscription must fail loudly rather than hang the screen.
      await joinChannel(channel);
    } catch (e) {
      // An unreachable server throws an SDK type (WebSocketChannelException,
      // SocketException, TimeoutException). Left unmapped it would be printed
      // on screen verbatim.
      leaveChannel(_client, channel, controller);
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
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
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
            'reply_to': ?replyTo,
            if (image.preview case final preview?)
              'attachment_preview': base64Encode(preview),
          })
          .select(_messageColumns)
          .single();
      // The sender already has the photo: never download it back.
      await _cache.write(path, image.bytes);
      return Ok(_toMessage(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Uint8List>> attachmentBytes(String attachmentPath) async {
    final cached = await _cache.read(attachmentPath);
    if (cached != null) return Ok(cached);
    try {
      // Straight from the private bucket under the same storage policy as a
      // signed URL: members of the conversation only.
      final bytes = await _client.storage
          .from('attachments')
          .download(attachmentPath);
      await _cache.write(attachmentPath, bytes);
      return Ok(bytes);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<ReadMark>>> readMarks(String conversationId) async {
    try {
      final rows = await _client.rpc(
        'read_marks',
        params: {'conversation': conversationId},
      ) as List<dynamic>;
      return Ok([
        for (final r in rows.cast<Map<String, dynamic>>())
          ReadMark(
            userId: r['user_id'] as String,
            shares: r['shares'] as bool,
            readAt: switch (r['read_at']) {
              final String at => DateTime.parse(at),
              _ => null,
            },
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId) async {
    // Sent by the database when a member who shares read status reads;
    // clients cannot send on this topic.
    final channel = _client.channel(
      'reads:$conversationId',
      opts: const RealtimeChannelConfig(private: true),
    );
    final reads = StreamController<ReadMark>();
    channel.onBroadcast(
      event: 'read',
      callback: (payload) {
        // Sent by the database (realtime.send), so the fields sit inside the
        // envelope's `payload`, unlike a client broadcast such as typing.
        final body = payload['payload'];
        if (body is! Map) return;
        final who = body['user_id'];
        final at = body['read_at'];
        if (who is String && at is String && !reads.isClosed) {
          reads.add(
            ReadMark(userId: who, shares: true, readAt: DateTime.parse(at)),
          );
        }
      },
    );
    reads.onCancel = () => leaveChannel(_client, channel);
    try {
      await joinChannel(channel);
    } catch (e) {
      leaveChannel(_client, channel, reads);
      return Err(_asFailure(e));
    }
    return Ok(reads.stream);
  }

  @override
  Future<Result<void>> forward(
    Message message,
    List<String> conversationIds,
  ) async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    try {
      for (final target in conversationIds) {
        String? path;
        final source = message.attachmentPath;
        if (source != null) {
          // Server-side copy into the target's folder: its members can read
          // it, and nothing is uploaded again.
          final ext = source.contains('.') ? source.split('.').last : 'jpg';
          path =
              '$target/${DateTime.now().microsecondsSinceEpoch}'
              '-${me.substring(0, 8)}.$ext';
          await _client.storage.from('attachments').copy(source, path);
        }
        await _client.from('messages').insert({
          'conversation_id': target,
          'sender_id': me,
          'body': message.body,
          'attachment_path': ?path,
          if (message.attachmentPreview case final preview?)
            'attachment_preview': base64Encode(preview),
          'forwarded': true,
        });
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> deleteForEveryone(Message message) async {
    try {
      final path = await _client.rpc(
        'delete_message',
        params: {'message': message.id},
      );
      if (path is String) {
        // The server has already taken the message's content; the photo
        // file follows. ponytail: a failed remove is not retried, leaving an
        // object no message points to (still listed in
        // app_private.deleted_attachments); add a scheduled sweep of that
        // list if it is ever seen to matter.
        try {
          await _client.storage.from('attachments').remove([path]);
        } catch (_) {}
        await _cache.remove(path);
      }
      return const Ok(null);
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
    attachmentPreview: _preview(row['attachment_preview']),
    replyTo: row['reply_to'] as String?,
    forwarded: row['forwarded'] as bool? ?? false,
    deletion: switch (row['deleted']) {
      'vanished' => MessageDeletion.vanished,
      'placeholder' => MessageDeletion.placeholder,
      _ => null,
    },
  );

  /// A preview that does not decode is dropped, never thrown: one bad row
  /// must not make a whole conversation unreadable. A missing preview only
  /// means the receiver waits for the photo.
  static Uint8List? _preview(Object? value) {
    if (value is! String) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }
}

/// Without a cache every look downloads again -- the behaviour before v0.9.
final class _NoCache implements AttachmentCache {
  const _NoCache();

  @override
  Future<Uint8List?> read(String path) async => null;

  @override
  Future<void> write(String path, Uint8List bytes) async {}

  @override
  Future<void> remove(String path) async {}

  @override
  Future<void> clear() async {}
}

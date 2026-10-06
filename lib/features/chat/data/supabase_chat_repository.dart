import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../../../data/realtime_channels.dart';
import '../../auth/domain/member.dart';
import '../domain/attachment.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/group_colors.dart';
import '../domain/group_event.dart';
import '../domain/group_member.dart';
import '../domain/group_settings.dart';
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

  /// The cap of the shared photos and links reads; a conversation screen reads
  /// pages instead (see [messagePageSize]).
  static const _historyLimit = 500;

  /// How many messages [messagesAround] fetches on each side of the anchor.
  static const _aroundWindow = 50;

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
      // profiles_public is readable to the same people profiles_read allows
      // (a contact, or someone the caller shares a conversation with); its
      // avatar_path is additionally null when the picture's own owner has
      // hidden it from this caller.
      final rows = await _client
          .rpc('profiles_public', params: const {}, get: true)
          .neq('user_id', me)
          .select('user_id, display_name, tag, avatar_path')
          .order('display_name')
          .retriedOnce();
      return Ok([
        for (final row in rows)
          Member(
            userId: row['user_id'] as String,
            displayName: row['display_name'] as String,
            tag: row['tag'] as String?,
            avatarPath: row['avatar_path'] as String?,
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<int>> unreadTotal() async {
    try {
      final n = await _client.rpc('unread_total');
      return Ok(n as int);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Conversation>>> conversations() async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    try {
      // Neither of these depends on the other's result, so they run
      // together instead of one after the other.
      final firstStage = await Future.wait<List<Map<String, dynamic>>>([
        // RLS returns membership rows only for conversations this member
        // belongs to, so this is already scoped — including the other
        // side's row.
        _client
            .from('conversation_members')
            .select('conversation_id, user_id, left_at, color_slot')
            .retriedOnce(),
        // Titles distinguish a group from a 1:1; RLS scopes this to the
        // caller's own conversations, same as the membership rows.
        _client
            .from('conversations')
            .select(
              'id, title, avatar_path, system, members_can_set_avatar, '
              'members_can_add, new_members_see_history',
            )
            .retriedOnce(),
      ]);
      final memberRows = firstStage[0];
      final conversationRows = firstStage[1];
      final titleById = {
        for (final row in conversationRows)
          row['id'] as String: row['title'] as String?,
      };
      final avatarPathById = {
        for (final row in conversationRows)
          row['id'] as String: row['avatar_path'] as String?,
      };
      final systemById = {
        for (final row in conversationRows)
          row['id'] as String: row['system'] == true,
      };
      final settingsById = {
        for (final row in conversationRows)
          row['id'] as String: GroupSettings(
            membersCanSetAvatar: row['members_can_set_avatar'] == true,
            membersCanAdd: row['members_can_add'] == true,
            newMembersSeeHistory: row['new_members_see_history'] != false,
          ),
      };

      final otherByConversation = <String, String>{};
      // Colour slots of the people in each group, and every other member's id
      // (named below, so a group's preview can name its sender).
      final slotByConversation = <String, Map<String, int>>{};
      final otherIds = <String>{};
      // The caller's own left_at, per conversation. A member who left and
      // was later re-added can hold more than one row for the same
      // conversation (the old row is kept, never rewritten): a current row
      // (left_at null) always wins over a past one, and among only-past
      // rows the most recent left_at wins.
      final myLeftAtByConversation = <String, DateTime?>{};
      for (final row in memberRows) {
        final userId = row['user_id'] as String;
        final conversationId = row['conversation_id'] as String;
        if (userId != me) {
          otherIds.add(userId);
          (slotByConversation[conversationId] ??= {})[userId] =
              row['color_slot'] as int? ?? 0;
          otherByConversation[conversationId] = userId;
          continue;
        }
        final leftAt = row['left_at'] == null
            ? null
            : DateTime.parse(row['left_at'] as String);
        final known = myLeftAtByConversation[conversationId];
        final knownIsCurrent =
            myLeftAtByConversation.containsKey(conversationId) && known == null;
        if (knownIsCurrent) continue; // a current row already wins outright
        if (leftAt == null || known == null || leftAt.isAfter(known)) {
          myLeftAtByConversation[conversationId] = leftAt;
        }
      }
      // A group is listed by its title, so it needs no "other" member; only
      // 1:1 conversations do.
      final conversationIds = {...titleById.keys, ...otherByConversation.keys};
      if (conversationIds.isEmpty) return const Ok([]);

      final others = otherIds.toList();
      // None of these three depends on either of the other two, so they
      // also run together rather than one after the other.
      final secondStage = await Future.wait<Object?>([
        others.isEmpty
            ? Future.value(const <Map<String, dynamic>>[])
            : _client
                  .rpc('profiles_public', params: const {}, get: true)
                  .inFilter('user_id', others)
                  .select('user_id, display_name, avatar_path')
                  .retriedOnce(),
        // Newest first, so the first row seen for a conversation is its
        // preview. One row per conversation, from a view that does the
        // DISTINCT ON in the database. A bounded scan across all
        // conversations used to lose the preview of a quiet one as soon as
        // enough newer messages existed elsewhere, which rendered as "No
        // messages yet" on a conversation that had messages.
        _client
            .from('conversation_previews')
            .select(
              'conversation_id, body, created_at, attachment_path, sender_id, deleted',
            )
            .retriedOnce(),
        // Only conversations with something unread come back.
        _client.rpc('unread_counts'),
      ]);
      final profileRows = secondStage[0]! as List<Map<String, dynamic>>;
      final recent = secondStage[1]! as List<Map<String, dynamic>>;
      final unreadRows = secondStage[2]! as List<dynamic>;
      final nameByUser = {
        for (final row in profileRows)
          row['user_id'] as String: row['display_name'] as String,
      };
      final avatarByUser = {
        for (final row in profileRows)
          row['user_id'] as String: row['avatar_path'] as String?,
      };
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
                    displayName: nameByUser[otherByConversation[id]!] ?? '',
                    avatarPath: avatarByUser[otherByConversation[id]!],
                  ),
            lastMessage: previewBy[id]?.body,
            lastMessageAt: previewBy[id]?.at,
            lastSenderId: previewBy[id]?.sender,
            unread: unreadBy[id] ?? 0,
            avatarPath: avatarPathById[id],
            hasLeft: myLeftAtByConversation[id] != null,
            isSystem: systemById[id] ?? false,
            settings: settingsById[id] ?? const GroupSettings(),
            senders: titleById[id] == null
                ? const {}
                : {
                    for (final e
                        in (slotByConversation[id] ?? const <String, int>{})
                            .entries)
                      e.key: GroupVoice(nameByUser[e.key] ?? '', e.value),
                  },
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
      'id, conversation_id, sender_id, body, created_at, attachment_path, attachment_preview, deleted, deleted_by, reply_to, forwarded, edited_at';

  /// The columns of a page read (open chat): no photo preview -- those arrive
  /// separately, see [attachmentPreviews], so the first paint never waits on
  /// them.
  static const _pageColumns =
      'id, conversation_id, sender_id, body, created_at, attachment_path, deleted, deleted_by, reply_to, forwarded, edited_at';

  @override
  Future<Result<List<Member>>> conversationMembers(
    String conversationId,
  ) async {
    try {
      // RLS returns these rows only to a member of the conversation.
      final rows = await _client
          .from('conversation_members')
          .select('user_id')
          .eq('conversation_id', conversationId)
          .retriedOnce();
      final ids = [for (final r in rows) r['user_id'] as String];
      if (ids.isEmpty) return const Ok([]);
      final profiles = await _client
          .rpc('profiles_public', params: const {}, get: true)
          .inFilter('user_id', ids)
          .select('user_id, display_name, tag, avatar_path')
          .order('display_name', ascending: true)
          .retriedOnce();
      return Ok([
        for (final p in profiles)
          Member(
            userId: p['user_id'] as String,
            displayName: p['display_name'] as String,
            tag: p['tag'] as String?,
            avatarPath: p['avatar_path'] as String?,
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<GroupMember>>> groupRoster(String conversationId) async {
    try {
      final convRows = await _client
          .from('conversations')
          .select('title')
          .eq('id', conversationId)
          .retriedOnce();
      // RLS (was_member) makes a conversation invisible to a caller who was
      // never a member of it -- convRows is empty in that case. A 1:1 has no
      // title -- groupRoster is for groups only.
      if (convRows.isEmpty || convRows.first['title'] == null) {
        return const Err(DeniedFailure());
      }
      // RLS returns these rows only to a caller who is or was in the
      // conversation, current members and past ones alike -- exactly what
      // the roster's "left" section needs. A rejoined person can hold more
      // than one row for this conversation (the old one is kept, never
      // rewritten -- see the server migration's own header comment); the
      // roster shows each PERSON once, so those collapse below to their
      // current row if they still have one, else their most recent past
      // row (security-lead F10) -- the same "current wins, else latest
      // left_at" rule the server's own mark_read uses.
      final rows = await _client
          .from('conversation_members')
          .select('user_id, role, left_at, left_reason, color_slot')
          .eq('conversation_id', conversationId)
          .retriedOnce();
      final byUser = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final userId = row['user_id'] as String;
        final leftAt = row['left_at'] as String?;
        final existing = byUser[userId];
        if (existing == null) {
          byUser[userId] = row;
          continue;
        }
        final existingLeftAt = existing['left_at'] as String?;
        if (existingLeftAt == null) continue; // a current row already wins
        if (leftAt == null ||
            DateTime.parse(leftAt).isAfter(DateTime.parse(existingLeftAt))) {
          byUser[userId] = row;
        }
      }
      final ids = byUser.keys.toList();
      if (ids.isEmpty) return const Ok([]);
      final profiles = await _client
          .rpc('profiles_public', params: const {}, get: true)
          .inFilter('user_id', ids)
          .select('user_id, display_name, tag, avatar_path')
          .retriedOnce();
      final byId = {for (final p in profiles) p['user_id'] as String: p};
      return Ok([
        for (final row in byUser.values)
          GroupMember(
            member: Member(
              userId: row['user_id'] as String,
              displayName:
                  byId[row['user_id']]?['display_name'] as String? ?? '',
              tag: byId[row['user_id']]?['tag'] as String?,
              avatarPath: byId[row['user_id']]?['avatar_path'] as String?,
            ),
            isAdmin: row['role'] == 'admin',
            colorSlot: row['color_slot'] as int? ?? 0,
            leftReason: row['left_at'] == null
                ? null
                : (row['left_reason'] == 'removed'
                      ? LeftReason.removed
                      : LeftReason.left),
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> leaveGroup(String conversationId) async {
    try {
      await _client.rpc(
        'leave_group',
        params: {'conversation': conversationId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> removeMember(
    String conversationId,
    String memberId,
  ) async {
    try {
      await _client.rpc(
        'remove_member',
        params: {'conversation': conversationId, 'member': memberId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> addMembers(
    String conversationId,
    List<String> memberIds, {
    required bool withHistory,
  }) async {
    try {
      await _client.rpc(
        'add_members',
        params: {
          'conversation': conversationId,
          'members': memberIds,
          'with_history': withHistory,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> setAdmin(
    String conversationId,
    String memberId, {
    required bool isAdmin,
  }) async {
    try {
      await _client.rpc(
        'set_admin',
        params: {
          'conversation': conversationId,
          'member': memberId,
          'is_admin': isAdmin,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<GroupEvent>>> groupEvents(String conversationId) async {
    try {
      // group_events_read scopes this to a current admin of the conversation;
      // anyone else, and any 1:1, simply gets no rows -- never a refusal.
      final rows = await _client
          .from('group_events')
          .select('id, conversation_id, kind, actor_id, subject_id, created_at')
          .eq('conversation_id', conversationId)
          .retriedOnce();
      return Ok([
        for (final row in rows)
          GroupEvent(
            id: row['id'] as String,
            conversationId: row['conversation_id'] as String,
            kind: switch (row['kind'] as String) {
              'removed' => GroupEventKind.removed,
              'added' => GroupEventKind.added,
              _ => GroupEventKind.left,
            },
            subjectId: row['subject_id'] as String,
            actorId: row['actor_id'] as String?,
            createdAt: DateTime.parse(row['created_at'] as String),
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
          .limit(_historyLimit)
          .retriedOnce();
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
          .limit(_historyLimit)
          .retriedOnce();
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
          .select(_pageColumns)
          .eq('conversation_id', conversationId)
          // Read NEWEST-first with a cap, then reverse. PostgREST truncates a
          // response at max_rows, and an ascending read would silently drop
          // the most recent messages -- a conversation frozen in the past,
          // which reads as working. Dropping the oldest is the honest
          // truncation.
          .order('created_at', ascending: false)
          .limit(messagePageSize)
          .retriedOnce();
      // The interface documents oldest-first, which is also what the screen
      // renders. One newest page; older history is paged with messagesAround.
      return Ok(rows.reversed.map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Map<String, Uint8List>>> attachmentPreviews(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const Ok({});
    try {
      final rows = await _client
          .from('messages')
          .select('id, attachment_preview')
          .inFilter('id', messageIds)
          .not('attachment_preview', 'is', null)
          .retriedOnce();
      return Ok({
        for (final row in rows)
          row['id'] as String: ?_preview(row['attachment_preview']),
      });
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message>> send({
    required String id,
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
      // created_at is withheld by the column-level grant; the server
      // assigns it, and returns the row so the caller need not wait for
      // the Realtime echo to display it. id comes from the caller
      // (randomMessageId) so a retried send after a lost answer is
      // idempotent -- see the unique_violation branch below.
      final row = await _client
          .from('messages')
          .insert({
            'id': id,
            'conversation_id': conversationId,
            'sender_id': me,
            'body': trimmed,
            'reply_to': ?replyTo,
          })
          .select(_messageColumns)
          .single();
      return Ok(_toMessage(row));
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // This id is already stored: an earlier attempt's insert reached
        // the server but its answer was lost. Read it back and accept it
        // as ours only if it truly is -- same sender, same conversation,
        // same text -- never on trust alone.
        try {
          final row = await _client
              .from('messages')
              .select(_messageColumns)
              .eq('id', id)
              .maybeSingle()
              .retriedOnce();
          // No row visible: either it truly is not there, or RLS is hiding
          // a row this sender cannot see -- both read as "not yours", never
          // a network failure.
          if (row == null) return const Err(DeniedFailure());
          final isOurs =
              row['sender_id'] == me &&
              row['conversation_id'] == conversationId &&
              row['body'] == trimmed &&
              (replyTo == null || row['reply_to'] == replyTo);
          if (!isOurs) return const Err(DeniedFailure());
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
  Future<Result<void>> setGroupAvatar(
    String conversationId,
    PickedImage? image, {
    String? previousPath,
  }) async {
    // Set once the upload actually succeeds, so a failed upload is never
    // "cleaned up" (there is nothing there to clean up).
    String? uploaded;
    try {
      String? path;
      if (image != null) {
        path =
            'group/$conversationId/${DateTime.now().microsecondsSinceEpoch}.${image.extension}';
        await _client.storage
            .from('avatars')
            .uploadBinary(
              path,
              image.bytes,
              fileOptions: FileOptions(contentType: image.contentType),
            );
        uploaded = path;
      }
      // The server's own record of the previous path, not the caller's --
      // the two can drift, and only the server's is ever right.
      final removed = await _client.rpc(
        'set_group_avatar',
        params: {'conversation': conversationId, 'path': path},
      ) as String?;
      if (removed != null) {
        try {
          await _client.storage.from('avatars').remove([removed]);
        } catch (_) {
          // Best-effort: the reference is already gone.
        }
      }
      return const Ok(null);
    } on PostgrestException catch (e) {
      // The server ran and definitely refused: the transaction rolled back,
      // so the upload (if any) points nowhere a row will ever read, and
      // removing it now is safe.
      if (uploaded != null) await _removeOrphanedAvatar(uploaded);
      // Not a member of a group, or the conversation is a 1:1.
      if (e.code == '22023') return const Err(DeniedFailure());
      return Err(_asFailure(e));
    } catch (e) {
      // Unreachable server, a dropped connection, a timeout: the RPC may have
      // committed and only the reply was lost. Deleting here could delete a
      // picture the server already started serving to everyone else -- worse
      // than leaving a possible orphan behind, so this never cleans up.
      return Err(_asFailure(e));
    }
  }

  /// Best-effort cleanup of an avatar object whose write to `profiles` or
  /// `conversations` never happened -- an unreachable server here already
  /// means offline, not a second failure to report.
  Future<void> _removeOrphanedAvatar(String path) async {
    try {
      await _client.storage.from('avatars').remove([path]);
    } catch (_) {}
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
  Future<Result<Uint8List>> avatarBytes(String avatarPath) async {
    final cached = await _cache.read(avatarPath);
    if (cached != null) return Ok(cached);
    try {
      final bytes = await _client.storage.from('avatars').download(avatarPath);
      await _cache.write(avatarPath, bytes);
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
            deliveredAt: switch (r['delivered_at']) {
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
  Future<Result<void>> markDelivered(
    String conversationId, {
    DateTime? upTo,
  }) async {
    try {
      await _client.rpc(
        'mark_delivered',
        params: {
          'conversation': conversationId,
          'up_to': upTo?.toUtc().toIso8601String(),
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<ReadMark>>> deliveredUpdates(
    String conversationId,
  ) async {
    // Sent by the database when any member's device receives messages; not
    // gated on read sharing; clients cannot send on this topic.
    final channel = _client.channel(
      'delivered:$conversationId',
      opts: const RealtimeChannelConfig(private: true),
    );
    final deliveries = StreamController<ReadMark>();
    channel.onBroadcast(
      event: 'delivered',
      callback: (payload) {
        // Sent by the database (realtime.send), so the fields sit inside the
        // envelope's `payload`, unlike a client broadcast such as typing.
        final body = payload['payload'];
        if (body is! Map) return;
        final who = body['user_id'];
        final at = body['delivered_at'];
        if (who is String && at is String && !deliveries.isClosed) {
          deliveries.add(
            ReadMark(
              userId: who,
              shares: false,
              deliveredAt: DateTime.parse(at),
            ),
          );
        }
      },
    );
    deliveries.onCancel = () => leaveChannel(_client, channel);
    try {
      await joinChannel(channel);
    } catch (e) {
      leaveChannel(_client, channel, deliveries);
      return Err(_asFailure(e));
    }
    return Ok(deliveries.stream);
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
          final removed = await _client.storage.from('attachments').remove([
            path,
          ]);
          if (removed.isEmpty) {
            log(
              'deleteForEveryone: photo file was not removed',
              name: 'sis.data',
              level: 900,
            );
          }
        } catch (e) {
          log(
            'deleteForEveryone: photo file removal failed: ${e.runtimeType}',
            name: 'sis.data',
            level: 900,
          );
        }
        await _cache.remove(path);
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> hideForMe(Message message) async {
    try {
      await _client.rpc('hide_message', params: {'message': message.id});
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Message>> editMessage(Message message, String body) async {
    try {
      final row = await _client.rpc(
        'edit_message',
        params: {'message': message.id, 'body': body.trim()},
      );
      return Ok(_toMessage(row as Map<String, dynamic>));
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

  @override
  Future<Result<List<Message>>> search(
    String query, {
    String? conversationId,
  }) async {
    try {
      final rows = await _client.rpc(
        'search_messages',
        params: {'query': query, 'conversation': conversationId},
      ) as List<dynamic>;
      return Ok(rows.cast<Map<String, dynamic>>().map(_toMessage).toList());
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Message>>> messagesAround(
    String conversationId,
    Message anchor,
  ) async {
    try {
      final anchorAt = anchor.createdAt.toUtc().toIso8601String();
      final before = await _client
          .from('messages')
          .select(_messageColumns)
          .eq('conversation_id', conversationId)
          .lte('created_at', anchorAt)
          .order('created_at', ascending: false)
          .limit(_aroundWindow + 1)
          .retriedOnce();
      final after = await _client
          .from('messages')
          .select(_messageColumns)
          .eq('conversation_id', conversationId)
          .gt('created_at', anchorAt)
          .order('created_at', ascending: true)
          .limit(_aroundWindow)
          .retriedOnce();
      // `before` comes back newest-first and includes the anchor itself
      // (>=); reversed, followed by `after` (strictly newer, ascending),
      // gives one oldest-first run centred on the anchor.
      return Ok([...before.reversed.map(_toMessage), ...after.map(_toMessage)]);
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
    editedAt: switch (row['edited_at']) {
      final String at => DateTime.parse(at).toLocal(),
      _ => null,
    },
    deletion: switch (row['deleted']) {
      'vanished' => MessageDeletion.vanished,
      'placeholder' => MessageDeletion.placeholder,
      _ => null,
    },
    deletedBy: row['deleted_by'] as String?,
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

import 'dart:typed_data';

import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import 'attachment.dart';
import 'conversation.dart';
import 'group_event.dart';
import 'group_member.dart';
import 'message.dart';
import 'read_marks.dart';

/// Chat boundary; the only way the app reaches conversations and messages.
///
/// Every call is subject to row-level security: the caller sees a conversation
/// only while it holds the active session and is a member. A repository never
/// throws — a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatRepository {
  /// Everyone else who can sign in, so a first conversation can be started.
  /// Without this there is no way to reach [startDirectConversation], which
  /// needs another member's id.
  Future<Result<List<Member>>> members();

  /// Conversations the signed-in member belongs to, most recent first.
  Future<Result<List<Conversation>>> conversations();

  /// Marks everything in [conversationId] read for the signed-in member, as of
  /// now. Only the member's own place moves; nobody else can see it.
  Future<Result<void>> markRead(String conversationId);

  /// Everyone in [conversationId], the caller included, by display name.
  Future<Result<List<Member>>> conversationMembers(String conversationId);

  /// The full roster of [conversationId], including anyone who has left or
  /// been removed (greyed in the app), for a GROUP only. The server refuses
  /// (DeniedFailure) for a 1:1 or for a conversation the caller was never in.
  Future<Result<List<GroupMember>>> groupRoster(String conversationId);

  /// Leaves [conversationId] (a group only). The conversation stays in the
  /// caller's list afterwards, read-only up to the moment they left. Refused
  /// (DeniedFailure) for a 1:1 or when the caller is not a current member.
  Future<Result<void>> leaveGroup(String conversationId);

  /// Removes [memberId] from [conversationId] (a group only). Admin-only,
  /// and never the caller's own id (leave instead). Refused otherwise.
  Future<Result<void>> removeMember(String conversationId, String memberId);

  /// Adds each of [memberIds] to [conversationId] (a group only), admin-only.
  /// [withHistory] chooses whether each new (or returning) member can read
  /// the group's existing history or only messages from now on. Each id must
  /// already be reachable by the caller (the contacts/reach rule) and
  /// allowlisted; one that is not fails the whole call. Already-current
  /// members are silently skipped.
  Future<Result<void>> addMembers(
    String conversationId,
    List<String> memberIds, {
    required bool withHistory,
  });

  /// Makes [memberId] an admin of [conversationId], or unmakes one,
  /// admin-only. Refused when this would leave the group with no admin at
  /// all.
  Future<Result<void>> setAdmin(
    String conversationId,
    String memberId, {
    required bool isAdmin,
  });

  /// "X left" / "X was removed" / "X was added" for [conversationId], in any
  /// order. Admin-only: the server's row-level security already refuses the
  /// rows to anyone else, so a non-admin (or a 1:1) simply gets an empty
  /// list, never a failure.
  Future<Result<List<GroupEvent>>> groupEvents(String conversationId);

  /// Messages with a photo in [conversationId], newest first, capped like
  /// [messages].
  Future<Result<List<Message>>> sharedMedia(String conversationId);

  /// Messages whose text contains a web address, newest first, capped like
  /// [messages]. Which part is the link is the caller's to extract.
  Future<Result<List<Message>>> sharedLinks(String conversationId);

  /// Messages in [conversationId], oldest first.
  Future<Result<List<Message>>> messages(String conversationId);

  /// Sends [body] to [conversationId] as message [id] and returns the
  /// stored message.
  ///
  /// [id] is generated on the phone (see `randomMessageId` in
  /// `domain/message.dart`), not assigned by the server, so a retried call
  /// with the same [id] after a lost answer is idempotent: the second
  /// insert is a primary-key conflict, and the implementation reads the
  /// already-stored row back as [Ok] instead of writing a duplicate or
  /// reporting a failure.
  ///
  /// The sender is the signed-in member; the server assigns the timestamp
  /// and returns the row it wrote. Returning it matters: a sender must
  /// never depend on the Realtime echo to see their own message, or a slow
  /// or dropped subscription means they send into silence.
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String body,
    String? replyTo,
  });

  /// Messages arriving in [conversationId] after subscription.
  ///
  /// The result arrives only once the server has confirmed the subscription,
  /// or as [Err] when the connection cannot be established at all — the same
  /// contract as every other call here, so an unreachable server reaches the
  /// screen as a reason rather than as a raw SDK exception.
  /// Realtime delivers nothing that happened before that moment, so a caller
  /// must await this BEFORE its initial [messages] read — otherwise a message
  /// sent in between is missed by the subscription and already too late for
  /// the read.
  ///
  /// Realtime delivery is a convenience, not an authority: the server
  /// re-checks the read policy for every subscriber.
  Future<Result<Stream<Message>>> incoming(String conversationId);

  /// Messages arriving in ANY conversation the member belongs to, for keeping
  /// the conversation list current. Row-level security decides which inserts
  /// reach this subscriber; nothing here filters for authorisation.
  Future<Result<Stream<Message>>> incomingAll();

  /// The id of the 1:1 conversation with [otherUserId], creating it when it does
  /// not exist yet. Calling twice returns the same conversation.
  Future<Result<String>> startDirectConversation(String otherUserId);

  /// Creates a group named [title] with [memberIds] plus the caller.
  ///
  /// Unlike [startDirectConversation] this always creates a new conversation:
  /// the same people may share several differently named groups. The call
  /// fails whole if any invitee is not a member, rather than quietly creating
  /// a smaller group than was asked for.
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  });

  /// Sets [conversationId]'s picture to [image], or clears it when null.
  /// Any member may call this, like a member-editable group name would be.
  /// [previousPath] (the group's avatarPath before this call, if any) is
  /// deleted from storage after the change succeeds. The server refuses
  /// (DeniedFailure) for a caller who is not a member, or for a 1:1
  /// conversation (which never has a picture of its own).
  Future<Result<void>> setGroupAvatar(
    String conversationId,
    PickedImage? image, {
    String? previousPath,
  });

  /// Uploads [image] into [conversationId] and sends it, with an optional
  /// caption in [body].
  ///
  /// The upload and the message are not atomic: an upload that succeeds and a
  /// message that then fails leaves an orphaned object, which is invisible
  /// (nothing references it) and cheap. The reverse -- a message pointing at
  /// an object that was never stored -- would be visible and broken, so the
  /// upload happens first.
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body,
    String? replyTo,
  });

  /// Sends a copy of [message] to each of [conversationIds], marked as
  /// forwarded. A photo is copied into each conversation (members of one
  /// conversation cannot read another's photos), never uploaded again.
  Future<Result<void>> forward(Message message, List<String> conversationIds);

  /// A short-lived URL for [attachmentPath], issued only to a member of the
  /// conversation the path names. The bucket is private; there is no public
  /// URL for an attachment.
  Future<Result<Uri>> attachmentUrl(String attachmentPath);

  /// The photo at [attachmentPath]: from this phone's cache when it is there,
  /// otherwise downloaded once (members of its conversation only) and kept.
  Future<Result<Uint8List>> attachmentBytes(String attachmentPath);

  /// The picture at [avatarPath] (a profile's or a group's): from this
  /// phone's cache when it is there, otherwise downloaded once (only to
  /// someone who could already read its owner) and kept.
  Future<Result<Uint8List>> avatarBytes(String avatarPath);

  /// How far each other member has read, where read status is shared.
  Future<Result<List<ReadMark>>> readMarks(String conversationId);

  /// Reads as they happen in [conversationId], from members who share read
  /// status, while the caller shares theirs. Resolves once subscribed.
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId);

  /// Deletes the member's own [message] for everyone, and its photo. The
  /// server refuses (DeniedFailure) when it is not theirs, already deleted,
  /// or over 6 hours old.
  Future<Result<void>> deleteForEveryone(Message message);

  /// Edits the member's own [message] to [body]: replaces its text, or a
  /// photo message's caption. Returns the updated message on success.
  ///
  /// The server refuses (DeniedFailure) exactly as [deleteForEveryone] does:
  /// not the caller's own message, no longer a member, deleted, forwarded,
  /// over 6 hours old, or a [body] that would not pass the same validation
  /// [send] applies -- a photo message may have an empty caption, a
  /// text-only message may not.
  Future<Result<Message>> editMessage(Message message, String body);

  /// Messages whose text contains [query], newest first, case-insensitively
  /// and Turkish-safely (the server folds İ, I and ı together before
  /// comparing, so "istanbul" finds "İstanbul", "ISTANBUL" and "ıstanbul").
  /// Scoped to [conversationId] when given, otherwise every conversation the
  /// caller is a member of. [query] shorter than three characters after
  /// trimming returns an empty list, never a failure. Capped at 50 hits, like
  /// every other capped read here.
  Future<Result<List<Message>>> search(String query, {String? conversationId});

  /// A window of messages around [anchor] in [conversationId], oldest first:
  /// up to 50 at or before [anchor]'s instant (so [anchor] itself is
  /// included -- a message sharing its exact instant counts as older) and up
  /// to 50 strictly after it. For jumping to a search hit that predates the
  /// conversation screen's own loaded history (see [messages]'s cap).
  Future<Result<List<Message>>> messagesAround(
    String conversationId,
    Message anchor,
  );
}

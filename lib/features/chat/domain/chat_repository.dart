import 'dart:typed_data';

import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import 'attachment.dart';
import 'conversation.dart';
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

  /// Messages with a photo in [conversationId], newest first, capped like
  /// [messages].
  Future<Result<List<Message>>> sharedMedia(String conversationId);

  /// Messages whose text contains a web address, newest first, capped like
  /// [messages]. Which part is the link is the caller's to extract.
  Future<Result<List<Message>>> sharedLinks(String conversationId);

  /// Messages in [conversationId], oldest first.
  Future<Result<List<Message>>> messages(String conversationId);

  /// Sends [body] to [conversationId] and returns the stored message.
  ///
  /// The sender is the signed-in member; the server assigns the id and the
  /// timestamp, and returns the row it wrote. Returning it matters: a sender
  /// must never depend on the Realtime echo to see their own message, or a
  /// slow or dropped subscription means they send into silence.
  Future<Result<Message>> send({
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

  /// How far each other member has read, where read status is shared.
  Future<Result<List<ReadMark>>> readMarks(String conversationId);

  /// Reads as they happen in [conversationId], from members who share read
  /// status, while the caller shares theirs. Resolves once subscribed.
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId);

  /// Deletes the member's own [message] for everyone, and its photo. The
  /// server refuses (DeniedFailure) when it is not theirs, already deleted,
  /// or over 6 hours old.
  Future<Result<void>> deleteForEveryone(Message message);
}

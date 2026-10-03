import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/date_label.dart';

/// The longest body the database will accept, per the check constraint on
/// `public.messages.body`.
const int maxMessageLength = 4000;

/// A random RFC 4122 v4 UUID, lowercase and hyphenated -- generated on the
/// phone as a text message's id, so a retried send after a lost answer is
/// idempotent: the server sees the same id twice and the second insert is a
/// primary-key conflict, read back as success, never a duplicate message.
String randomMessageId() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Whether [body] alone would be accepted as a message.
///
/// This is the rule for a TEXT-only message, applied before the round trip so
/// the composer can refuse instead of surfacing a constraint violation. It is
/// deliberately stricter than `messages_body_check`, which since attachments
/// also accepts an empty body when a message carries an image — a caption-less
/// photo goes through `sendImage`, never through here.
bool isSendableBody(String body) {
  final trimmed = body.trim();
  return trimmed.isNotEmpty && trimmed.length <= maxMessageLength;
}

/// The one-line preview of a message in the conversation list. An image sent
/// without a caption has an empty body, which would read as "no messages".
String previewText(Message message) => message.body.isNotEmpty
    ? message.body
    : (message.hasAttachment ? 'Photo' : '');

/// The local clock time of [at], always HH:MM -- whatever day it falls on.
/// What a chat bubble shows: unlike [previewTime] it never falls back to a date, since a bubble is already anchored in its conversation's order.
String clockTime(DateTime at) =>
    '${twoDigit(at.toLocal().hour)}:${twoDigit(at.toLocal().minute)}';

/// The time shown next to a preview: the clock time today, the date before.
String previewTime(DateTime at, DateTime now) =>
    isSameLocalDay(at, now) ? clockTime(at) : dateTail(at);

/// One message in a conversation.
final class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.attachmentPath,
    this.attachmentPreview,
    this.localImage,
    this.deletion,
    this.deletedBy,
    this.editedAt,
    this.replyTo,
    this.forwarded = false,
    this.sending = false,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String body;
  final DateTime createdAt;

  /// Storage key of an attached image, or null for a text-only message.
  final String? attachmentPath;

  /// The tiny preview sent with a photo, shown blurred until the photo loads.
  final Uint8List? attachmentPreview;

  /// The sender's own photo while it is still uploading: shown at once from
  /// the phone, before the server has it. Such a message is not yet stored.
  final Uint8List? localImage;

  bool get hasAttachment => attachmentPath != null || localImage != null;

  /// The message this one answers, in the same conversation.
  final String? replyTo;

  /// A copy of a message from another conversation.
  final bool forwarded;

  /// True for a text-only message shown at once, before the server has
  /// answered -- like [localImage] but with nothing to display in the
  /// bubble itself, only the pending state ([isPending]).
  final bool sending;

  /// Set when it was deleted for everyone; its content is gone.
  final MessageDeletion? deletion;

  /// Who deleted it for everyone: its sender, or a group admin.
  final String? deletedBy;

  /// When the sender last edited this message's body, or null if never
  /// edited. No history is kept: only the latest body survives.
  final DateTime? editedAt;

  bool get isDeleted => deletion != null;

  /// A group admin deleted it, not its sender.
  bool get deletedByAdmin => deletedBy != null && deletedBy != senderId;

  bool get isEdited => editedAt != null;

  /// Whether [me] may delete this for everyone: it is stored, not yet
  /// deleted, and theirs -- or [admin] (a group admin may delete any
  /// member's message). No time limit (the server checks too).
  bool canDeleteForEveryone(String me, {bool admin = false}) =>
      !isPending && deletion == null && (senderId == me || admin);

  /// Whether [me] may still edit this message at [now]: their own, stored,
  /// not deleted, not forwarded, and under 6 hours old (the server checks
  /// too).
  bool canEdit(String me, DateTime now) =>
      senderId == me &&
      !isPending &&
      deletion == null &&
      !forwarded &&
      now.difference(createdAt) < deleteForEveryoneWindow;

  /// Still on its way to the server: a photo shown from the phone before
  /// the upload lands, or a text message shown before the server answers.
  bool get isPending =>
      sending || (localImage != null && attachmentPath == null);

  /// Whether this is the pending photo bubble that [stored] is the stored
  /// row of: same caption and the same preview bytes, which each photo has of
  /// its own, so two photos in the air with one caption pair up correctly.
  /// ponytail: a side without a preview matches on caption alone.
  bool isPendingOf(Message stored) {
    if (localImage == null || attachmentPath != null) return false;
    if (body != stored.body) return false;
    final a = attachmentPreview, b = stored.attachmentPreview;
    if (a == null || b == null) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// A copy of this message carrying [bytes] as its [localImage]: a stored
  /// photo message keeps showing the phone's own copy of the photo it was
  /// sent from, so nothing is swapped when the stored row replaces the
  /// pending bubble.
  Message withLocalImage(Uint8List? bytes) => Message(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    body: body,
    createdAt: createdAt,
    attachmentPath: attachmentPath,
    attachmentPreview: attachmentPreview,
    localImage: bytes,
    deletion: deletion,
    deletedBy: deletedBy,
    editedAt: editedAt,
    replyTo: replyTo,
    forwarded: forwarded,
    sending: sending,
  );

  /// Whether [userId] wrote this message; decides which side it is drawn on.
  bool isFrom(String userId) => senderId == userId;
}

/// Whether [messages] (oldest first) at [index] starts a run: the first
/// message, or one whose sender differs from the message before it. A group
/// conversation names the sender only at the start of each run.
bool startsRun(List<Message> messages, int index) =>
    index == 0 || messages[index - 1].senderId != messages[index].senderId;

/// How long after sending a message its sender may still edit it.
const deleteForEveryoneWindow = Duration(hours: 6);

/// What a delete for everyone left behind. A new delete always leaves the
/// "This message was deleted" placeholder; `vanished` is only what older
/// deletes (within an hour of sending) left, as if never sent.
enum MessageDeletion { vanished, placeholder }

/// Mirrors public.fold_search exactly: İ, I and ı all fold to plain 'i',
/// then the rest is lowercased -- so "istanbul" matches "İstanbul",
/// "ISTANBUL" and "ıstanbul" the same way the server's search does.
String foldSearch(String input) {
  return input
      .replaceAll('İ', 'i')
      .replaceAll('I', 'i')
      .replaceAll('ı', 'i')
      .toLowerCase();
}

/// Whether [query] is worth a search: at least three letters or digits (any
/// script) once trimmed. Symbol-only or emoji-only queries never search --
/// the server's search_messages enforces the same rule, so this only saves
/// the round trip.
bool isSearchable(String query) =>
    RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(query.trim()).length >= 3;

/// One action a member may take on a message: reply, forward, edit their
/// own text/caption, delete (for me, or for everyone: their own, or any
/// member's for a group admin), copy the text (tap menu only), or, on their
/// own message, see who has read it.
enum MessageAction { readBy, reply, forward, edit, delete, copy }

/// The actions [me] may take on [message] at [now], in the order they are
/// offered -- reply and forward need a stored message with something in
/// it; edit and delete for everyone are the sender's own message within
/// [deleteForEveryoneWindow]; read-by shows on your own message in every
/// chat, groups and 1:1, alongside reply/forward. This is the single source of truth for
/// "what does this message allow": both the swipe action row and each
/// bubble's screen-reader custom actions read it, so the rule lives once.
List<MessageAction> allowedMessageActions(
  Message message, {
  required String? me,
  required DateTime now,
  bool admin = false,
}) {
  final canDelete =
      me != null && message.canDeleteForEveryone(me, admin: admin);
  final canEdit = me != null && message.canEdit(me, now);
  final canShare = !message.isPending && !message.isDeleted;
  final canSeeReaders = me != null && message.isFrom(me) && canShare;
  return [
    if (canSeeReaders) MessageAction.readBy,
    if (canShare) MessageAction.reply,
    if (canShare) MessageAction.forward,
    if (canEdit) MessageAction.edit,
    if (canDelete) MessageAction.delete,
  ];
}

/// The actions the tap menu offers for [message], in order: reply, copy
/// (text present, not deleted), forward, edit (own text within the
/// edit window) and delete (any stored message: the dialog then offers
/// delete for me, and delete for everyone only when
/// [Message.canDeleteForEveryone] allows). Copy is never in the swipe row.
List<MessageAction> menuMessageActions(
  Message message, {
  required String? me,
  required DateTime now,
}) {
  final canShare = !message.isPending && !message.isDeleted;
  final canEdit = me != null && message.canEdit(me, now);
  return [
    if (canShare) MessageAction.reply,
    if (canShare && message.body.isNotEmpty) MessageAction.copy,
    if (canShare) MessageAction.forward,
    if (canEdit) MessageAction.edit,
    if (!message.isPending) MessageAction.delete,
  ];
}

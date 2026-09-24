import 'dart:typed_data';

/// The longest body the database will accept, per the check constraint on
/// `public.messages.body`.
const int maxMessageLength = 4000;

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

/// The time shown next to a preview: the clock time today, the date before.
String previewTime(DateTime at, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = at.toLocal();
  final today = now.toLocal();
  if (local.year == today.year &&
      local.month == today.month &&
      local.day == today.day) {
    return '${two(local.hour)}:${two(local.minute)}';
  }
  return '${two(local.day)}.${two(local.month)}.${two(local.year % 100)}';
}

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
    this.replyTo,
    this.forwarded = false,
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

  /// Set when the sender deleted it for everyone; its content is gone.
  final MessageDeletion? deletion;

  bool get isDeleted => deletion != null;

  /// Whether [me] may still delete this for everyone at [now]: their own,
  /// stored, not yet deleted, and under 6 hours old (the server checks too).
  bool canDeleteForEveryone(String me, DateTime now) =>
      senderId == me &&
      !isPending &&
      deletion == null &&
      now.difference(createdAt) < deleteForEveryoneWindow;

  /// Still on its way to the server.
  bool get isPending => localImage != null && attachmentPath == null;

  /// Whether [userId] wrote this message; decides which side it is drawn on.
  bool isFrom(String userId) => senderId == userId;
}

/// Whether [messages] (oldest first) at [index] starts a run: the first
/// message, or one whose sender differs from the message before it. A group
/// conversation names the sender only at the start of each run.
bool startsRun(List<Message> messages, int index) =>
    index == 0 || messages[index - 1].senderId != messages[index].senderId;

/// How long after sending a message its sender may delete it for everyone.
const deleteForEveryoneWindow = Duration(hours: 6);

/// What a delete for everyone left behind. Within an hour of sending the
/// message vanishes as if never sent; after that, "This message was
/// deleted" stays in its place.
enum MessageDeletion { vanished, placeholder }

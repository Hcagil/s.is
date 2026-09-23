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
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String body;
  final DateTime createdAt;

  /// Storage key of an attached image, or null for a text-only message.
  final String? attachmentPath;

  bool get hasAttachment => attachmentPath != null;

  /// Whether [userId] wrote this message; decides which side it is drawn on.
  bool isFrom(String userId) => senderId == userId;
}

/// Whether [messages] (oldest first) at [index] starts a run: the first
/// message, or one whose sender differs from the message before it. A group
/// conversation names the sender only at the start of each run.
bool startsRun(List<Message> messages, int index) =>
    index == 0 || messages[index - 1].senderId != messages[index].senderId;

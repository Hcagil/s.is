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

/// The longest body the database will accept; mirrors the check constraint on
/// `public.messages.body`.
const int maxMessageLength = 4000;

/// Whether [body] would be accepted by the database.
///
/// The same rule as the `messages_body_check` constraint, applied before the
/// round trip so the composer can disable sending instead of surfacing a
/// constraint violation.
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

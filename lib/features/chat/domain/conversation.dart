import '../../auth/domain/member.dart';

/// A 1:1 conversation as the conversation list needs it.
///
/// v0.2 is one-to-one only, so a conversation is identified by the other
/// member. v0.3 adds group conversations and this gains a title and a member
/// list instead.
final class Conversation {
  const Conversation({
    required this.id,
    required this.other,
    this.lastMessage,
    this.lastMessageAt,
  });

  final String id;
  final Member other;

  /// Preview of the most recent message, or null when nothing has been sent.
  final String? lastMessage;
  final DateTime? lastMessageAt;
}

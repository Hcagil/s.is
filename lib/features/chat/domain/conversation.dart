import '../../auth/domain/member.dart';
import 'message.dart';

/// A conversation as the conversation list needs it.
///
/// A conversation is a **group** when it has a [title]; a 1:1 conversation has
/// no title and names the other member instead. That is the same distinction
/// the database makes, where a 1:1 carries a unique `direct_key` and a group
/// carries a title.
final class Conversation {
  const Conversation({
    required this.id,
    this.title,
    this.other,
    this.lastMessage,
    this.lastMessageAt,
    this.lastSenderId,
    this.unread = 0,
  });

  final String id;

  /// Set for a group, null for a 1:1.
  final String? title;

  /// Set for a 1:1, null for a group.
  final Member? other;

  /// Preview of the most recent message, or null when nothing has been sent.
  final String? lastMessage;
  final DateTime? lastMessageAt;

  /// Who wrote [lastMessage], so the list can say "You:".
  final String? lastSenderId;

  /// Messages from others since the member last opened this conversation.
  final int unread;

  /// The same conversation with a newer message as its preview; [unread]
  /// grows by one when [counts] (a message from someone else, arriving while
  /// this conversation is not open).
  Conversation withPreview(Message message, {bool counts = false}) =>
      Conversation(
        id: id,
        title: title,
        other: other,
        lastMessage: previewText(message),
        lastMessageAt: message.createdAt,
        lastSenderId: message.senderId,
        unread: counts ? unread + 1 : unread,
      );

  /// The same conversation with nothing unread.
  Conversation read() => Conversation(
    id: id,
    title: title,
    other: other,
    lastMessage: lastMessage,
    lastMessageAt: lastMessageAt,
    lastSenderId: lastSenderId,
  );

  bool get isGroup => title != null;

  /// What the list shows: the group's title, or who you are talking to.
  String get label => title ?? other?.displayName ?? 'Conversation';
}

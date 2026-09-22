import '../../auth/domain/member.dart';

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
  });

  final String id;

  /// Set for a group, null for a 1:1.
  final String? title;

  /// Set for a 1:1, null for a group.
  final Member? other;

  /// Preview of the most recent message, or null when nothing has been sent.
  final String? lastMessage;
  final DateTime? lastMessageAt;

  bool get isGroup => title != null;

  /// What the list shows: the group's title, or who you are talking to.
  String get label => title ?? other?.displayName ?? 'Conversation';
}

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
    this.avatarPath,
    this.hasLeft = false,
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

  /// The group's own picture, or null for none (and always null for a 1:1 -- see [other]).
  final String? avatarPath;

  /// True once the signed-in member has left or been removed from a group;
  /// the conversation stays in the list, read-only. Always false for a 1:1.
  final bool hasLeft;

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
        avatarPath: avatarPath,
        hasLeft: hasLeft,
      );

  /// The same conversation with nothing unread.
  Conversation read() => Conversation(
    id: id,
    title: title,
    other: other,
    lastMessage: lastMessage,
    lastMessageAt: lastMessageAt,
    lastSenderId: lastSenderId,
    avatarPath: avatarPath,
    hasLeft: hasLeft,
  );

  /// For the on-disk chat list snapshot only.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'other': other?.toJson(),
    'lastMessage': lastMessage,
    'lastMessageAt': lastMessageAt?.toIso8601String(),
    'lastSenderId': lastSenderId,
    'unread': unread,
    'avatarPath': avatarPath,
    'hasLeft': hasLeft,
  };

  static Conversation fromJson(Map<String, Object?> json) => Conversation(
    id: json['id'] as String,
    title: json['title'] as String?,
    other: json['other'] == null
        ? null
        : Member.fromJson(json['other'] as Map<String, Object?>),
    lastMessage: json['lastMessage'] as String?,
    lastMessageAt: json['lastMessageAt'] == null
        ? null
        : DateTime.parse(json['lastMessageAt'] as String),
    lastSenderId: json['lastSenderId'] as String?,
    unread: json['unread'] as int? ?? 0,
    avatarPath: json['avatarPath'] as String?,
    hasLeft: json['hasLeft'] as bool? ?? false,
  );

  bool get isGroup => title != null;

  /// What the list shows: the group's title, or who you are talking to.
  String get label => title ?? other?.displayName ?? 'Conversation';
}

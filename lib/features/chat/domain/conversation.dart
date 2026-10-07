import '../../auth/domain/member.dart';
import 'group_colors.dart';
import 'group_settings.dart';
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
    this.isSystem = false,
    this.senders = const {},
    this.settings = const GroupSettings(),
    this.archived = false,
    this.pinned = false,
    this.pinnedMessageId,
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

  /// True for the read-only SIS system chat that carries What's-new notes;
  /// nobody can write into it or leave it.
  final bool isSystem;

  /// For a group: each other member's name and colour slot by user id, so the
  /// list can name and colour the sender of the preview. Empty for a 1:1.
  final Map<String, GroupVoice> senders;

  /// A group's admin-controlled switches; meaningless for a 1:1.
  final GroupSettings settings;

  /// True when the signed-in member archived this chat (per member; server-side, so it follows them across devices). Archived chats leave the main list and stay archived when new messages arrive.
  final bool archived;

  /// True when the signed-in member pinned this chat (per member; server-side). Pinned chats sit at the top of the list, up to 5.
  final bool pinned;

  /// The id of the one message pinned in this chat (shared by everyone in it), or null.
  final String? pinnedMessageId;

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
        isSystem: isSystem,
        senders: senders,
        settings: settings,
        archived: archived,
        pinned: pinned,
        pinnedMessageId: pinnedMessageId,
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
    isSystem: isSystem,
    senders: senders,
    settings: settings,
    archived: archived,
    pinned: pinned,
    pinnedMessageId: pinnedMessageId,
  );

  /// The same conversation with [next] as its settings.
  Conversation withSettings(GroupSettings next) => Conversation(
    id: id,
    title: title,
    other: other,
    lastMessage: lastMessage,
    lastMessageAt: lastMessageAt,
    lastSenderId: lastSenderId,
    unread: unread,
    avatarPath: avatarPath,
    hasLeft: hasLeft,
    isSystem: isSystem,
    senders: senders,
    settings: next,
    archived: archived,
    pinned: pinned,
    pinnedMessageId: pinnedMessageId,
  );

  /// The same conversation, archived or not.
  Conversation withArchived(bool value) => Conversation(
    id: id,
    title: title,
    other: other,
    lastMessage: lastMessage,
    lastMessageAt: lastMessageAt,
    lastSenderId: lastSenderId,
    unread: unread,
    avatarPath: avatarPath,
    hasLeft: hasLeft,
    isSystem: isSystem,
    senders: senders,
    settings: settings,
    archived: value,
    pinned: pinned,
    pinnedMessageId: pinnedMessageId,
  );

  /// The same conversation, pinned or not.
  Conversation withPinned(bool value) => Conversation(
    id: id,
    title: title,
    other: other,
    lastMessage: lastMessage,
    lastMessageAt: lastMessageAt,
    lastSenderId: lastSenderId,
    unread: unread,
    avatarPath: avatarPath,
    hasLeft: hasLeft,
    isSystem: isSystem,
    senders: senders,
    settings: settings,
    archived: archived,
    pinned: value,
    pinnedMessageId: pinnedMessageId,
  );

  /// The same conversation with [messageId] as its pinned message (null: none).
  Conversation withPinnedMessage(String? messageId) => Conversation(
    id: id,
    title: title,
    other: other,
    lastMessage: lastMessage,
    lastMessageAt: lastMessageAt,
    lastSenderId: lastSenderId,
    unread: unread,
    avatarPath: avatarPath,
    hasLeft: hasLeft,
    isSystem: isSystem,
    senders: senders,
    settings: settings,
    archived: archived,
    pinned: pinned,
    pinnedMessageId: messageId,
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
    'isSystem': isSystem,
    'senders': {for (final e in senders.entries) e.key: e.value.toJson()},
    'settings': settings.toJson(),
    // Written only when true: the saved list the native side reads keeps its
    // old shape for every un-archived chat.
    if (archived) 'archived': true,
    if (pinned) 'pinned': true,
    if (pinnedMessageId != null) 'pinnedMessageId': pinnedMessageId,
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
    isSystem: json['isSystem'] as bool? ?? false,
    senders: {
      for (final e
          in ((json['senders'] as Map<String, Object?>?) ??
                  const <String, Object?>{})
              .entries)
        e.key: GroupVoice.fromJson(e.value! as Map<String, Object?>),
    },
    settings: json['settings'] == null
        ? const GroupSettings()
        : GroupSettings.fromJson(json['settings'] as Map<String, Object?>),
    archived: json['archived'] as bool? ?? false,
    pinned: json['pinned'] as bool? ?? false,
    pinnedMessageId: json['pinnedMessageId'] as String?,
  );

  bool get isGroup => title != null;

  /// The group's title, or who you are talking to. Empty when the partner's
  /// name is unknown; presentation localises that via conversationLabel.
  String get label => isSystem ? 'SIS' : title ?? other?.displayName ?? '';
}

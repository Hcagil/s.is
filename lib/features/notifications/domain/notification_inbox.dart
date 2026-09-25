/// The notifications waiting in the phone's shade for one chat: its title as
/// the server worded it, and its newest lines, oldest first.
final class InboxChat {
  const InboxChat({
    required this.conversationId,
    required this.title,
    required this.lines,
    required this.count,
  });

  final String conversationId;
  final String title;

  /// At most [maxInboxLines], oldest first.
  final List<String> lines;

  /// Every message received for this chat since it was last opened.
  final int count;

  Map<String, Object> toJson() => {
    'c': conversationId,
    't': title,
    'l': lines,
    'n': count,
  };

  static InboxChat fromJson(Map<String, Object?> j) => InboxChat(
    conversationId: j['c'] as String,
    title: j['t'] as String,
    lines: [for (final l in j['l'] as List) l as String],
    count: j['n'] as int,
  );
}

/// How many lines one chat's notification keeps.
const maxInboxLines = 6;

/// [inbox] (chats in the order they last received something, oldest first)
/// with one more message for [conversationId]: the chat moves to the end,
/// takes the latest [title], appends [body] (keeping the newest
/// [maxInboxLines]) and counts one more.
List<InboxChat> addToInbox(
  List<InboxChat> inbox, {
  required String conversationId,
  required String title,
  required String body,
}) {
  final existing = inbox
      .where((c) => c.conversationId == conversationId)
      .firstOrNull;
  final all = [...?existing?.lines, body];
  return [
    for (final c in inbox)
      if (c.conversationId != conversationId) c,
    InboxChat(
      conversationId: conversationId,
      title: title,
      lines: all.length > maxInboxLines
          ? all.sublist(all.length - maxInboxLines)
          : all,
      count: (existing?.count ?? 0) + 1,
    ),
  ];
}

/// [inbox] without [conversationId]: the member opened that chat.
List<InboxChat> removeFromInbox(List<InboxChat> inbox, String conversationId) =>
    [
      for (final c in inbox)
        if (c.conversationId != conversationId) c,
    ];

/// The one-line summary over everything waiting: '1 new message',
/// 'N new messages', with ' in K chats' when more than one chat is waiting.
/// Empty inbox -> ''.
String inboxSummary(List<InboxChat> inbox) {
  if (inbox.isEmpty) return '';
  final total = inbox.fold(0, (sum, c) => sum + c.count);
  final messages = total == 1 ? '1 new message' : '$total new messages';
  return inbox.length > 1 ? '$messages in ${inbox.length} chats' : messages;
}

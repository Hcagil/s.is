/// One message line in a chat's notification.
final class InboxLine {
  const InboxLine({
    required this.sender,
    required this.text,
    required this.at,
    this.id,
  });

  final String sender;
  final String text;

  /// Milliseconds since the epoch, when the push arrived.
  final int at;

  /// The push's message id, used to drop a line stored twice.
  final String? id;

  Map<String, Object> toJson() => {'s': sender, 'x': text, 'a': at, 'm': ?id};

  /// [j] is a stored map, or a bare string (the format before per-line
  /// senders existed).
  static InboxLine fromJson(Object? j) {
    if (j is String) return InboxLine(sender: '', text: j, at: 0);
    final m = j as Map<String, Object?>;
    return InboxLine(
      sender: m['s'] as String,
      text: m['x'] as String,
      at: m['a'] as int,
      id: m['m'] as String?,
    );
  }
}

/// The notification waiting in the phone's shade for one chat: its title, and
/// its newest lines, oldest first.
final class InboxChat {
  const InboxChat({
    required this.conversationId,
    required this.title,
    required this.group,
    required this.lines,
    required this.count,
    required this.posted,
  });

  final String conversationId;

  /// The chat's title: the group's name, or the person for a 1:1.
  final String title;
  final bool group;

  /// At most [maxInboxLines], oldest first.
  final List<InboxLine> lines;

  /// Every message received for this chat since it was last opened.
  final int count;

  /// How many of [count] are already inside a posted notification.
  final int posted;

  Map<String, Object> toJson() => {
    'c': conversationId,
    't': title,
    'g': group,
    'l': [for (final l in lines) l.toJson()],
    'n': count,
    'p': posted,
  };

  static InboxChat fromJson(Map<String, Object?> j) {
    final n = j['n'] as int;
    return InboxChat(
      conversationId: j['c'] as String,
      title: j['t'] as String,
      group: j['g'] as bool? ?? false,
      lines: [for (final l in j['l'] as List) InboxLine.fromJson(l)],
      count: n,
      posted: j['p'] as int? ?? n,
    );
  }

  InboxChat withPosted(int posted) => InboxChat(
    conversationId: conversationId,
    title: title,
    group: group,
    lines: lines,
    count: count,
    posted: posted,
  );
}

/// How many lines one chat's notification keeps: what Android's
/// MessagingStyle holds (it drops anything past 25 itself).
const maxInboxLines = 25;

/// The server words a group message's title 'Sender @ Group', and a 1:1's
/// (or a sender-only preview's) as just the name.
({String chat, String sender, bool group}) parsePushTitle(String title) {
  final i = title.indexOf(' @ ');
  if (i < 0) return (chat: title, sender: title, group: false);
  return (
    chat: title.substring(i + 3),
    sender: title.substring(0, i),
    group: true,
  );
}

/// [inbox] (chats in the order they last received something, oldest first)
/// with one more message for [conversationId]: the chat moves to the end,
/// takes the latest title, appends [body] as a line from the title's sender
/// (keeping the newest [maxInboxLines]) and counts one more. The server's
/// separate [sender] and [chat] (a group message) win over parsing [title].
List<InboxChat> addToInbox(
  List<InboxChat> inbox, {
  required String conversationId,
  required String title,
  required String body,
  String? sender,
  String? chat,
  String? messageId,
  required DateTime at,
}) {
  final parsed = sender != null && chat != null
      ? (chat: chat, sender: sender, group: true)
      : parsePushTitle(title);
  final existing = inbox
      .where((c) => c.conversationId == conversationId)
      .firstOrNull;
  // Already stored (the Android receiver draws a push before this runs).
  if (messageId != null &&
      (existing?.lines.any((l) => l.id == messageId) ?? false)) {
    return inbox;
  }
  final all = [
    ...?existing?.lines,
    InboxLine(
      sender: parsed.sender,
      text: body,
      at: at.millisecondsSinceEpoch,
      id: messageId,
    ),
  ];
  return [
    for (final c in inbox)
      if (c.conversationId != conversationId) c,
    InboxChat(
      conversationId: conversationId,
      title: parsed.chat,
      group: parsed.group,
      lines: all.length > maxInboxLines
          ? all.sublist(all.length - maxInboxLines)
          : all,
      count: (existing?.count ?? 0) + 1,
      posted: existing?.posted ?? 0,
    ),
  ];
}

/// [inbox] without [conversationId]: the member opened that chat.
List<InboxChat> removeFromInbox(List<InboxChat> inbox, String conversationId) =>
    [
      for (final c in inbox)
        if (c.conversationId != conversationId) c,
    ];

/// The chats holding messages no posted notification shows yet.
List<InboxChat> dirtyChats(List<InboxChat> inbox) => [
  for (final c in inbox)
    if (c.count != c.posted) c,
];

/// [inbox] with every listed chat recorded as fully posted.
List<InboxChat> markPosted(
  List<InboxChat> inbox,
  Set<String> conversationIds,
) => [
  for (final c in inbox)
    conversationIds.contains(c.conversationId) ? c.withPosted(c.count) : c,
];

/// The one-line summary over everything waiting: '1 new message',
/// 'N new messages', with ' from K chats' when more than one chat is waiting.
/// Empty inbox -> ''.
String inboxSummary(List<InboxChat> inbox) {
  if (inbox.isEmpty) return '';
  final total = inbox.fold(0, (sum, c) => sum + c.count);
  final messages = total == 1 ? '1 new message' : '$total new messages';
  return inbox.length > 1 ? '$messages from ${inbox.length} chats' : messages;
}

/// The name of the person a line is shown as: the line's own sender, else the
/// chat's title for a 1:1 (the other person), else null (a group line of
/// unknown sender).
String? lineSenderName(InboxChat chat, InboxLine line) {
  if (line.sender.isNotEmpty) return line.sender;
  return chat.group ? null : chat.title;
}

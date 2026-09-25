/// How far one other member of a conversation has read, as far as read
/// status is shared between the two of you. When it is not shared either way
/// (mutual, like last seen), [shares] is false and [readAt] null.
final class ReadMark {
  const ReadMark({required this.userId, required this.shares, this.readAt});

  final String userId;
  final bool shares;
  final DateTime? readAt;

  /// Whether this member has read a message sent at [sentAt].
  bool hasRead(DateTime sentAt) =>
      shares && readAt != null && !readAt!.isBefore(sentAt);
}

/// Whether a message sent at [sentAt] shows as read: at least one other
/// member who shares read status has read it (in a group, one reader is
/// enough — read status is not "read by all"). When nobody shares it there
/// is nothing to show, and the message looks normal.
bool isReadByAnyone(List<ReadMark> marks, DateTime sentAt) {
  final sharers = marks.where((m) => m.shares);
  return sharers.isEmpty || sharers.any((m) => m.hasRead(sentAt));
}

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

/// Whether a message sent at [sentAt] shows as read: every other member who
/// shares read status has read it. When nobody shares it there is nothing to
/// show, and the message looks normal.
bool isReadByAll(List<ReadMark> marks, DateTime sentAt) =>
    marks.where((m) => m.shares).every((m) => m.hasRead(sentAt));

/// How far one other member of a conversation has read, as far as read
/// status is shared between the two of you. When it is not shared either way
/// (mutual, like last seen), [shares] is false and [readAt] null.
final class ReadMark {
  const ReadMark({
    required this.userId,
    required this.shares,
    this.readAt,
    this.deliveredAt,
  });

  final String userId;
  final bool shares;
  final DateTime? readAt;

  /// Up to when this member's device has received the conversation's
  /// messages (the server's delivered_at); independent of [shares]: a member
  /// with read receipts off still reports delivery.
  final DateTime? deliveredAt;

  /// Whether this member's device has received a message sent at [sentAt].
  bool hasDelivered(DateTime sentAt) =>
      deliveredAt != null && !deliveredAt!.isBefore(sentAt);

  ReadMark copyWith({bool? shares, DateTime? readAt, DateTime? deliveredAt}) =>
      ReadMark(
        userId: userId,
        shares: shares ?? this.shares,
        readAt: readAt ?? this.readAt,
        deliveredAt: deliveredAt ?? this.deliveredAt,
      );

  /// Whether this member has read a message sent at [sentAt].
  bool hasRead(DateTime sentAt) =>
      shares && readAt != null && !readAt!.isBefore(sentAt);
}

/// The members who have read a message sent at [sentAt], earliest reader
/// first. [marks] is not changed.
List<ReadMark> readersOf(List<ReadMark> marks, DateTime sentAt) =>
    marks.where((m) => m.hasRead(sentAt)).toList()
      ..sort((a, b) => a.readAt!.compareTo(b.readAt!));

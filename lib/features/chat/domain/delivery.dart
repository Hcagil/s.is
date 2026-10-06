import 'message.dart';
import 'read_marks.dart';

/// What a sender's tick shows for one of their messages.
enum Delivery { pending, sent, delivered, read }

/// Where [message] stands, from the sender's side.
///
/// One tick = sent. Two grey ticks = delivered to EVERY recipient (in a
/// group, everyone). Two blue ticks = READ by every recipient. A recipient
/// with read receipts off ([ReadMark.shares] false) never counts as read, so
/// the message stays at two grey ticks (assumption, see the slice 5 PR).
/// Recipients are the [marks] of everyone but the sender.
///
/// Delivery comes from [ReadMark.deliveredAt] (the server records it per
/// member, whether or not that member shares read status).
Delivery deliveryOf(Message message, List<ReadMark> marks) {
  if (message.isPending) return Delivery.pending;
  final recipients = marks.where((m) => m.userId != message.senderId).toList();
  if (recipients.isEmpty) return Delivery.sent;
  final sentAt = message.createdAt;
  if (recipients.every((m) => m.hasRead(sentAt))) return Delivery.read;
  if (recipients.every((m) => m.hasDelivered(sentAt) || m.hasRead(sentAt))) {
    return Delivery.delivered;
  }
  return Delivery.sent;
}

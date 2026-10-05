import 'message.dart';
import 'read_marks.dart';

/// What a sender's tick shows for one of their messages.
enum Delivery { pending, sent, delivered, read }

/// Where [message] stands, from the sender's side.
///
/// One tick = sent. Two grey ticks = delivered to EVERY recipient (in a
/// group, everyone). Two blue ticks = READ by every recipient. A recipient
/// with read receipts off ([ReadMark.shares] false) never counts as read, so
/// the message stays at its last non-read state. Recipients are the [marks]
/// of everyone but the sender.
///
/// The server records no per-member delivery today (only
/// conversation_members.last_read_at / shared_read_at), so callers pass the
/// default empty [deliveredTo] and [Delivery.delivered] stays unreachable
/// until it does.
Delivery deliveryOf(
  Message message,
  List<ReadMark> marks, {
  Set<String> deliveredTo = const {},
}) {
  if (message.sending) return Delivery.pending;
  final recipients = marks.where((m) => m.userId != message.senderId).toList();
  if (recipients.isEmpty) return Delivery.sent;
  final sentAt = message.createdAt;
  if (recipients.every((m) => m.hasRead(sentAt))) return Delivery.read;
  if (recipients.every(
    (m) => deliveredTo.contains(m.userId) || m.hasRead(sentAt),
  )) {
    return Delivery.delivered;
  }
  return Delivery.sent;
}

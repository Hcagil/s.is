// The tick rule (owner rule Q7) from the server's delivery positions
// (ReadMark.deliveredAt), written from the contract only:
//   clock = pending; one tick = sent; two grey = delivered to EVERY
//   recipient; two blue = read by EVERY recipient; a member with read
//   receipts off never counts as read; no recipients = sent.
// The server snaps delivered_at to a message's own created_at, so a
// position equal to the message's time means "delivered". Run under
// TZ=JST-9: instants compare as instants, whatever zone they are held in.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';

final sentAt = DateTime.utc(2026, 10, 5, 12);
final after = sentAt.add(const Duration(minutes: 1));
final before = sentAt.subtract(const Duration(minutes: 1));

Message msg({bool sending = false, String from = 'me'}) => Message(
  id: 'm1',
  conversationId: 'c1',
  senderId: from,
  body: 'hi',
  createdAt: sentAt,
  sending: sending,
);

/// A recipient: [got] = delivered up to, [read] = read up to (shared).
ReadMark r(String id, {DateTime? got, DateTime? read, bool shares = true}) =>
    ReadMark(userId: id, shares: shares, readAt: read, deliveredAt: got);

void main() {
  group('ReadMark.hasDelivered', () {
    test('null position: not delivered', () {
      expect(r('a').hasDelivered(sentAt), isFalse);
    });
    test('position before the message: not delivered', () {
      expect(r('a', got: before).hasDelivered(sentAt), isFalse);
    });
    test('position exactly at the message (the server snaps to it): '
        'delivered', () {
      expect(r('a', got: sentAt).hasDelivered(sentAt), isTrue);
    });
    test('position after: delivered', () {
      expect(r('a', got: after).hasDelivered(sentAt), isTrue);
    });
    test('independent of shares: receipts off still reports delivery', () {
      expect(r('a', got: after, shares: false).hasDelivered(sentAt), isTrue);
    });
    test('the same instant held in local time and in UTC compares equal', () {
      expect(r('a', got: sentAt.toLocal()).hasDelivered(sentAt), isTrue);
      expect(
        r('a', got: before.toLocal()).hasDelivered(sentAt.toLocal()),
        isFalse,
      );
    });
  });

  group('ReadMark.copyWith', () {
    final base = r('a', got: before, read: before);
    test('no arguments: every field kept', () {
      final c = base.copyWith();
      expect(
        (c.userId, c.shares, c.readAt, c.deliveredAt),
        ('a', true, before, before),
      );
    });
    test('deliveredAt alone: read fields kept', () {
      final c = base.copyWith(deliveredAt: after);
      expect(
        (c.userId, c.shares, c.readAt, c.deliveredAt),
        ('a', true, before, after),
      );
    });
    test('readAt and shares alone: delivery kept', () {
      final c = base.copyWith(readAt: after, shares: false);
      expect(
        (c.userId, c.shares, c.readAt, c.deliveredAt),
        ('a', false, after, before),
      );
    });
  });

  group('deliveryOf, 1:1', () {
    test('pending wins over everything', () {
      expect(
        deliveryOf(msg(sending: true), [r('b', got: after, read: after)]),
        Delivery.pending,
      );
    });
    test('no recipients: sent', () {
      expect(deliveryOf(msg(), const []), Delivery.sent);
      expect(
        deliveryOf(msg(), [r('me', got: after, read: after)]),
        Delivery.sent,
        reason: 'the sender\'s own mark is not a recipient',
      );
    });
    test('stored, not delivered: one tick', () {
      expect(deliveryOf(msg(), [r('b')]), Delivery.sent);
      expect(deliveryOf(msg(), [r('b', got: before)]), Delivery.sent);
    });
    test('delivered (deliveredAt), not read: two grey', () {
      expect(deliveryOf(msg(), [r('b', got: sentAt)]), Delivery.delivered);
      expect(
        deliveryOf(msg(), [r('b', got: after, read: before)]),
        Delivery.delivered,
      );
    });
    test('read: two blue', () {
      expect(
        deliveryOf(msg(), [r('b', got: after, read: after)]),
        Delivery.read,
      );
    });
    test('receipts off: delivered stays two grey, never blue', () {
      expect(
        deliveryOf(msg(), [r('b', got: after, shares: false)]),
        Delivery.delivered,
      );
      expect(
        deliveryOf(msg(), [r('b', shares: false)]),
        Delivery.sent,
        reason: 'and not delivered is still one tick',
      );
    });
    test('receipts off with a read time on the mark: still never blue', () {
      // A member who read and then turned receipts off: the time is there,
      // the read must not count.
      expect(
        deliveryOf(msg(), [r('b', got: after, read: after, shares: false)]),
        Delivery.delivered,
      );
    });
  });

  group('deliveryOf, group', () {
    test('delivered to some but not every recipient: one tick', () {
      expect(
        deliveryOf(msg(), [r('b', got: after), r('c'), r('d', got: after)]),
        Delivery.sent,
      );
    });
    test('delivered to every recipient: two grey', () {
      expect(
        deliveryOf(msg(), [
          r('b', got: after),
          r('c', got: sentAt),
          r('d', got: after),
        ]),
        Delivery.delivered,
      );
    });
    test('read by some, delivered to the rest: two grey', () {
      expect(
        deliveryOf(msg(), [
          r('b', got: after, read: after),
          r('c', got: after),
        ]),
        Delivery.delivered,
      );
    });
    test('read by some, one not even delivered: one tick', () {
      expect(
        deliveryOf(msg(), [r('b', got: after, read: after), r('c')]),
        Delivery.sent,
      );
    });
    test('read by every recipient: two blue', () {
      expect(
        deliveryOf(msg(), [
          r('b', got: after, read: after),
          r('c', got: after, read: after),
        ]),
        Delivery.read,
      );
    });
    test('everyone read but one member has receipts off: two grey', () {
      expect(
        deliveryOf(msg(), [
          r('b', got: after, read: after),
          r('c', got: after, shares: false),
        ]),
        Delivery.delivered,
      );
    });
    test('the sender\'s own mark never holds the ticks back', () {
      expect(
        deliveryOf(msg(), [r('me'), r('b', got: after, read: after)]),
        Delivery.read,
      );
      expect(
        deliveryOf(msg(), [r('me'), r('b', got: after)]),
        Delivery.delivered,
      );
    });
    test('deliveredTo and deliveredAt combine per member', () {
      expect(
        deliveryOf(msg(), [r('b', got: after), r('c')], deliveredTo: {'c'}),
        Delivery.delivered,
      );
    });
  });
}

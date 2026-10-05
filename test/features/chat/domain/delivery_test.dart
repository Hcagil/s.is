import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';

/// Helper to create a message with a fixed createdAt.
Message msg({bool sending = false}) => Message(
  id: 'msg1',
  conversationId: 'conv1',
  senderId: 'me',
  body: 'Hello',
  createdAt: DateTime.utc(2026, 10, 5, 12),
  sending: sending,
);

/// Helper to create a read mark for a user.
ReadMark readMark(String userId, {bool shares = true, DateTime? readAt}) =>
    ReadMark(userId: userId, shares: shares, readAt: readAt);

/// Read time is one minute after the message creation.
final _readAt = msg().createdAt.add(const Duration(minutes: 1));

/// Read time before the message creation.
final _beforeReadAt = msg().createdAt.subtract(const Duration(minutes: 1));

void main() {
  group('deliveryOf', () {
    test('sending message with all recipients read -> pending', () {
      final message = msg(sending: true);
      final marks = [
        readMark('alice', readAt: _readAt),
        readMark('bob', readAt: _readAt),
      ];
      expect(deliveryOf(message, marks), Delivery.pending);
    });

    test('empty marks -> sent', () {
      final message = msg();
      expect(deliveryOf(message, []), Delivery.sent);
    });

    test('only the sender\'s own mark (read) -> sent', () {
      final message = msg();
      final marks = [readMark('me', readAt: _readAt)];
      expect(deliveryOf(message, marks), Delivery.sent);
    });

    test('1:1: other has read -> read', () {
      final message = msg();
      final marks = [readMark('alice', readAt: _readAt)];
      expect(deliveryOf(message, marks), Delivery.read);
    });

    test('1:1: other not read, not in deliveredTo -> sent', () {
      final message = msg();
      final marks = [readMark('alice', readAt: _beforeReadAt)];
      expect(deliveryOf(message, marks), Delivery.sent);
    });

    test('1:1: other in deliveredTo, not read -> delivered', () {
      final message = msg();
      final marks = [readMark('alice', readAt: _beforeReadAt)];
      expect(
        deliveryOf(message, marks, deliveredTo: {'alice'}),
        Delivery.delivered,
      );
    });

    test('1:1: readAt before createdAt, not delivered -> sent', () {
      final message = msg();
      final marks = [readMark('alice', readAt: _beforeReadAt)];
      expect(deliveryOf(message, marks), Delivery.sent);
    });

    test('group of 3 recipients: all read -> read', () {
      final message = msg();
      final marks = [
        readMark('alice', readAt: _readAt),
        readMark('bob', readAt: _readAt),
        readMark('carol', readAt: _readAt),
      ];
      expect(deliveryOf(message, marks), Delivery.read);
    });

    test('group: two read, one not read and not delivered -> sent', () {
      final message = msg();
      final marks = [
        readMark('alice', readAt: _readAt),
        readMark('bob', readAt: _readAt),
        readMark('carol', readAt: _beforeReadAt),
      ];
      expect(deliveryOf(message, marks), Delivery.sent);
    });

    test('group: two read, one in deliveredTo -> delivered', () {
      final message = msg();
      final marks = [
        readMark('alice', readAt: _readAt),
        readMark('bob', readAt: _readAt),
        readMark('carol', readAt: _beforeReadAt),
      ];
      expect(
        deliveryOf(message, marks, deliveredTo: {'carol'}),
        Delivery.delivered,
      );
    });

    test('group: deliveredTo partial (2 of 3), none read -> sent', () {
      final message = msg();
      final marks = [
        readMark('alice', readAt: _beforeReadAt),
        readMark('bob', readAt: _beforeReadAt),
        readMark('carol', readAt: _beforeReadAt),
      ];
      expect(
        deliveryOf(message, marks, deliveredTo: {'alice', 'bob'}),
        Delivery.sent,
      );
    });

    test('group: deliveredTo full (all 3), none read -> delivered', () {
      final message = msg();
      final marks = [
        readMark('alice', readAt: _beforeReadAt),
        readMark('bob', readAt: _beforeReadAt),
        readMark('carol', readAt: _beforeReadAt),
      ];
      expect(
        deliveryOf(message, marks, deliveredTo: {'alice', 'bob', 'carol'}),
        Delivery.delivered,
      );
    });

    test('receipts-off member (shares false, readAt set) in 1:1, in deliveredTo -> delivered, never read', () {
      final message = msg();
      final marks = [readMark('alice', shares: false, readAt: _readAt)];
      expect(
        deliveryOf(message, marks, deliveredTo: {'alice'}),
        Delivery.delivered,
      );
    });

    test('group: all others read, one receipts-off member in deliveredTo -> delivered (capped, not read)', () {
      final message = msg();
      final marks = [
        readMark('alice', readAt: _readAt),
        readMark('bob', readAt: _readAt),
        readMark('carol', shares: false, readAt: _readAt),
      ];
      expect(
        deliveryOf(message, marks, deliveredTo: {'carol'}),
        Delivery.delivered,
      );
    });

    test(
      'group: receipts-off member NOT in deliveredTo, others read -> sent',
      () {
        final message = msg();
        final marks = [
          readMark('alice', readAt: _readAt),
          readMark('bob', readAt: _readAt),
          readMark('carol', shares: false, readAt: _readAt),
        ];
        expect(deliveryOf(message, marks), Delivery.sent);
      },
    );

    test('sender\'s own unread mark does not block read: sender mark readAt null, other recipient read -> read', () {
      final message = msg();
      final marks = [
        readMark('me', readAt: null),
        readMark('alice', readAt: _readAt),
      ];
      expect(deliveryOf(message, marks), Delivery.read);
    });

    test('deliveredTo containing only the sender id with a recipient unread -> sent', () {
      final message = msg();
      final marks = [readMark('alice', readAt: _beforeReadAt)];
      expect(deliveryOf(message, marks, deliveredTo: {'me'}), Delivery.sent);
    });
  });
}

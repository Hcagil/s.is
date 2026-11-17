import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';

const bob = Member(userId: 'u2', displayName: 'Bob');

Conversation conv({int unread = 0}) => Conversation(
  id: 'c1',
  other: bob,
  lastMessage: 'hi',
  lastMessageAt: DateTime.utc(2026, 11, 3, 9),
  lastSenderId: 'u2',
  unread: unread,
);

void main() {
  group('Conversation marked unread', () {
    test('1 default: unread 0 -> markedUnread false, isUnread false', () {
      final c = conv();
      expect(c.unread, 0);
      expect(c.markedUnread, false);
      expect(c.isUnread, false);
    });

    test('2 unread 3 -> isUnread true, markedUnread false', () {
      final c = conv(unread: 3);
      expect(c.unread, 3);
      expect(c.markedUnread, false);
      expect(c.isUnread, true);
    });

    test(
      '3 unread 0 + withMarkedUnread(true) -> isUnread true, unread still 0',
      () {
        final c = conv().withMarkedUnread(true);
        expect(c.unread, 0);
        expect(c.markedUnread, true);
        expect(c.isUnread, true);
      },
    );

    test(
      '4 withMarkedUnread(true) then withMarkedUnread(false) -> isUnread false',
      () {
        final c = conv().withMarkedUnread(true).withMarkedUnread(false);
        expect(c.unread, 0);
        expect(c.markedUnread, false);
        expect(c.isUnread, false);
      },
    );

    test('5 unread 2 + mark, then read() -> unread 0, markedUnread false, isUnread false', () {
      final c = conv(unread: 2).withMarkedUnread(true).read();
      expect(c.unread, 0);
      expect(c.markedUnread, false);
      expect(c.isUnread, false);
    });

    test('6 marked chat: toJson() containsKey \'markedUnread\' == true value true; round trip keeps markedUnread true and id', () {
      final c = conv().withMarkedUnread(true);
      final json = c.toJson();
      expect(json.containsKey('markedUnread'), true);
      expect(json['markedUnread'], true);

      final roundTrip = Conversation.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(roundTrip.markedUnread, true);
      expect(roundTrip.id, c.id);
    });

    test('7 unmarked chat: toJson() does NOT containKey \'markedUnread\'; round trip gives markedUnread false', () {
      final c = conv();
      final json = c.toJson();
      expect(json.containsKey('markedUnread'), false);

      final roundTrip = Conversation.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(roundTrip.markedUnread, false);
    });

    test('8 fromJson of a map produced by an unmarked chat\'s toJson with \'markedUnread\' removed explicitly -> false (old snapshot)', () {
      final c = conv();
      final json = c.toJson();
      final modified = Map<String, dynamic>.from(json);
      modified.remove('markedUnread');

      final fromOld = Conversation.fromJson(modified);
      expect(fromOld.markedUnread, false);
    });
  });
}

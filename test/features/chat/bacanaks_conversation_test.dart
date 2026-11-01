import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';

void main() {
  group('Conversation', () {
    const member = Member(userId: 'u2', displayName: 'Bob');

    test('toJson writes isBacanaks only when true', () {
      final convTrue = const Conversation(
        id: 'c1',
        title: 'Anything',
        other: member,
        isAdminChat: true,
        isBacanaks: true,
      );
      final jsonTrue = convTrue.toJson();
      expect(jsonTrue.containsKey('isBacanaks'), isTrue);
      expect(jsonTrue['isBacanaks'], isTrue);

      final convFalse = const Conversation(
        id: 'c2',
        title: 'Anything',
        other: member,
        isAdminChat: true,
        isBacanaks: false,
      );
      final jsonFalse = convFalse.toJson();
      expect(jsonFalse.containsKey('isBacanaks'), isFalse);
    });

    test('fromJson preserves isBacanaks', () {
      final conv = const Conversation(
        id: 'c3',
        title: 'Anything',
        other: member,
        isAdminChat: true,
        isBacanaks: true,
      );
      final json = conv.toJson();
      final convFromJson = Conversation.fromJson(json);
      expect(convFromJson.isBacanaks, isTrue);
    });

    test('fromJson of map without isBacanaks sets false', () {
      final map = const Conversation(id: 'c4', title: 'Anything').toJson();
      expect(map.containsKey('isBacanaks'), isFalse);
      final conv = Conversation.fromJson(map);
      expect(conv.isBacanaks, isFalse);
    });

    test('label for Bacanaks admin chat is "Bacanaks Özel"', () {
      final conv = const Conversation(
        id: 'c5',
        title: 'Anything',
        other: member,
        isAdminChat: true,
        isBacanaks: true,
      );
      expect(conv.label, equals('Bacanaks Özel'));
    });

    test('label for admin chat without Bacanaks is not "Bacanaks Özel"', () {
      final conv = const Conversation(
        id: 'c6',
        title: 'Anything',
        other: member,
        isAdminChat: true,
        isBacanaks: false,
      );
      expect(conv.label, isNot(equals('Bacanaks Özel')));
    });

    test('label for normal titled conversation is title', () {
      final conv = const Conversation(id: 'c7', title: 'Work');
      expect(conv.label, equals('Work'));
    });
  });
}

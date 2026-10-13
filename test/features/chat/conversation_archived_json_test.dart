import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/auth/domain/member.dart';

const Member _member = Member(userId: 'u-d', displayName: 'Deniz');

Conversation _conv({bool archived = false}) => Conversation(
  id: 'c-1',
  title: 'Chat',
  other: _member,
  lastMessage: 'Hello',
  lastMessageAt: DateTime.utc(2026, 10, 7, 9),
  lastSenderId: 'u-d',
  unread: 5,
  archived: archived,
);

void main() {
  test('withArchived(true) on an unarchived conversation', () {
    final original = _conv(archived: false);
    final updated = original.withArchived(true);

    expect(updated.archived, isTrue);
    expect(updated.id, equals(original.id));
    expect(updated.other?.userId, equals(original.other?.userId));
    expect(updated.lastMessage, equals(original.lastMessage));
    expect(updated.lastMessageAt, equals(original.lastMessageAt));
    expect(updated.unread, equals(original.unread));
  });

  test('withArchived(false) on an archived conversation', () {
    final original = _conv(archived: true);
    final updated = original.withArchived(false);

    expect(updated.archived, isFalse);
    expect(updated.id, equals(original.id));
    expect(updated.other?.userId, equals(original.other?.userId));
    expect(updated.lastMessage, equals(original.lastMessage));
    expect(updated.lastMessageAt, equals(original.lastMessageAt));
    expect(updated.unread, equals(original.unread));
  });

  test('Round trip preserves archived flag and other fields', () {
    final original = _conv(archived: true);
    final json = original.toJson();
    final roundTripped = Conversation.fromJson(json);

    expect(roundTripped.archived, isTrue);
    expect(roundTripped.id, equals(original.id));
    expect(roundTripped.lastMessage, equals(original.lastMessage));
    expect(roundTripped.unread, equals(original.unread));
  });

  test('Round trip of an unarchived conversation', () {
    final original = _conv(archived: false);
    final json = original.toJson();
    final roundTripped = Conversation.fromJson(json);

    expect(roundTripped.archived, isFalse);
    expect(roundTripped.id, equals(original.id));
    expect(roundTripped.lastMessage, equals(original.lastMessage));
    expect(roundTripped.unread, equals(original.unread));
  });

  test('Round trip through real JSON text', () {
    final original = _conv(archived: true);
    final jsonString = jsonEncode(original.toJson());
    final decoded = jsonDecode(jsonString) as Map<String, Object?>;
    final roundTripped = Conversation.fromJson(decoded);

    expect(roundTripped.archived, isTrue);
    expect(roundTripped.id, equals(original.id));
    expect(roundTripped.lastMessage, equals(original.lastMessage));
    expect(roundTripped.unread, equals(original.unread));
  });

  test('Missing archived key defaults to false', () {
    final original = _conv(archived: false);
    final json = original.toJson();
    final jsonWithoutArchived = Map<String, Object?>.from(json)
      ..remove('archived');
    final roundTripped = Conversation.fromJson(jsonWithoutArchived);

    expect(roundTripped.archived, isFalse);
    expect(roundTripped.id, equals(original.id));
    expect(roundTripped.lastMessage, equals(original.lastMessage));
    expect(roundTripped.unread, equals(original.unread));
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/group_settings.dart';
import 'package:sis/features/chat/domain/chat_pin_repository.dart';
import 'package:sis/features/chat/domain/group_event.dart';

/// Helper to create a conversation used in several tests.
Conversation _conv({bool archived = false}) => Conversation(
      id: 'c-1',
      title: 'Chat',
      other: const Member(userId: 'u-d', displayName: 'Deniz'),
      lastMessage: 'Hello',
      lastMessageAt: DateTime.utc(2026, 10, 7, 9),
      lastSenderId: 'u-d',
      unread: 5,
      archived: archived,
    );

void main() {
  final now = DateTime.utc(2026, 9, 24, 12);

  group('menuMessageActions pin/unpin behaviour', () {
    test('someone else fresh text: pin present, unpin absent, correct order', () {
      final msg = Message(
        id: '1',
        conversationId: 'c1',
        senderId: 'user2',
        body: 'Hi',
        createdAt: now,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(actions, contains(MessageAction.pin));
      expect(actions, isNot(contains(MessageAction.unpin)));
      expect(actions.indexOf(MessageAction.forward), lessThan(actions.indexOf(MessageAction.pin)));
      expect(actions.indexOf(MessageAction.pin), lessThan(actions.indexOf(MessageAction.deleteForMe)));
    });

    test('own fresh text: pin after edit, before deleteForMe', () {
      final msg = Message(
        id: '2',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(actions, contains(MessageAction.pin));
      expect(actions.indexOf(MessageAction.edit), lessThan(actions.indexOf(MessageAction.pin)));
      expect(actions.indexOf(MessageAction.pin), lessThan(actions.indexOf(MessageAction.deleteForMe)));
    });

    test('pinned message: unpin present, pin absent, correct order', () {
      final msg = Message(
        id: '3',
        conversationId: 'c1',
        senderId: 'user2',
        body: 'Hi',
        createdAt: now,
      );
      final actions = menuMessageActions(msg,
          me: 'user1', now: now, pinned: true);
      expect(actions, contains(MessageAction.unpin));
      expect(actions, isNot(contains(MessageAction.pin)));
      expect(actions.indexOf(MessageAction.forward), lessThan(actions.indexOf(MessageAction.unpin)));
      expect(actions.indexOf(MessageAction.unpin), lessThan(actions.indexOf(MessageAction.deleteForMe)));
    });

    test('canPin false: neither pin nor unpin', () {
      final msg = Message(
        id: '4',
        conversationId: 'c1',
        senderId: 'user2',
        body: 'Hi',
        createdAt: now,
      );
      final actions = menuMessageActions(msg,
          me: 'user1', now: now, canPin: false);
      expect(actions, isNot(contains(MessageAction.pin)));
      expect(actions, isNot(contains(MessageAction.unpin)));
    });

    test('deleted placeholder: no pin/unpin even if canPin true', () {
      final msg = Message(
        id: '5',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
        deletion: MessageDeletion.placeholder,
      );
      final actions = menuMessageActions(msg,
          me: 'user1', now: now, canPin: true);
      expect(actions, isNot(contains(MessageAction.pin)));
      expect(actions, isNot(contains(MessageAction.unpin)));
    });

    test('pending sending message: no pin/unpin even if canPin true', () {
      final msg = Message(
        id: '6',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
        sending: true,
      );
      final actions = menuMessageActions(msg,
          me: 'user1', now: now, canPin: true);
      expect(actions, isNot(contains(MessageAction.pin)));
      expect(actions, isNot(contains(MessageAction.unpin)));
    });
  });

  group('Conversation.withPinned and withPinnedMessage', () {
    test('withPinned(true) preserves other fields', () {
      final original = _conv();
      final pinned = original.withPinned(true);
      expect(pinned.pinned, isTrue);
      expect(pinned.id, equals(original.id));
      expect(pinned.lastMessage, equals(original.lastMessage));
      expect(pinned.unread, equals(original.unread));
      expect(pinned.archived, equals(original.archived));
    });

    test('withPinned(false) restores pinned flag', () {
      final original = _conv();
      final pinned = original.withPinned(true);
      final unpinned = pinned.withPinned(false);
      expect(unpinned.pinned, isFalse);
    });

    test('withPinnedMessage sets pinnedMessageId without changing pinned', () {
      final original = _conv();
      final updated = original.withPinnedMessage('m9');
      expect(updated.pinnedMessageId, equals('m9'));
      expect(updated.pinned, isFalse);
    });

    test('withPinnedMessage(null) clears pinnedMessageId', () {
      final original = _conv();
      final updated = original.withPinnedMessage('m9').withPinnedMessage(null);
      expect(updated.pinnedMessageId, isNull);
    });
  });

  group('Conversation JSON round‑trip with pinned fields', () {
    test('pinned conversation survives JSON encode/decode', () {
      final conv = _conv()
          .withPinned(true)
          .withPinnedMessage('m9');
      final json = conv.toJson();
      final roundTrip = Conversation.fromJson(json);
      expect(roundTrip.pinned, isTrue);
      expect(roundTrip.pinnedMessageId, equals('m9'));
    });

    test('old build map without pinned keys defaults to false/null', () {
      final conv = _conv();
      final json = conv.toJson();
      final oldJson = Map<String, Object?>.from(json)
        ..remove('pinned')
        ..remove('pinnedMessageId');
      final roundTrip = Conversation.fromJson(oldJson);
      expect(roundTrip.pinned, isFalse);
      expect(roundTrip.pinnedMessageId, isNull);
    });
  });

  group('GroupSettings defaults and round‑trip', () {
    test('default membersCanPin is true', () {
      const settings = GroupSettings();
      expect(settings.membersCanPin, isTrue);
    });

    test('fromJson without membersCanPin defaults to true', () {
      final settings = GroupSettings.fromJson({});
      expect(settings.membersCanPin, isTrue);
    });

    test('copyWith(false) round‑trips correctly', () {
      final settings = GroupSettings().copyWith(membersCanPin: false);
      final json = settings.toJson();
      expect(json['membersCanPin'], isFalse);
      final roundTrip = GroupSettings.fromJson(json);
      expect(roundTrip.membersCanPin, isFalse);
    });
  });

  group('Constants and enums', () {
    test('maxPinnedChats is 5', () {
      expect(maxPinnedChats, equals(5));
    });

    test('GroupEventKind contains pinned', () {
      expect(GroupEventKind.values, contains(GroupEventKind.pinned));
      expect(GroupEventKind.pinned.name, equals('pinned'));
    });
  });
}

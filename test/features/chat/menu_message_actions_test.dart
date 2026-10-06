// menuMessageActions (Update 1 slice 7), from its contract: reply, copy,
// forward, edit, pin, delete for me, delete for everyone -- in that order,
// each only when its rule holds. Run under TZ=JST-9.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  final now = DateTime.utc(2026, 9, 24, 12);

  group('menuMessageActions', () {
    test('own fresh text gives all actions', () {
      final msg = Message(
        id: '1',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('someone else\'s text gives limited actions', () {
      final msg = Message(
        id: '2',
        conversationId: 'c1',
        senderId: 'user2',
        body: 'Hi',
        createdAt: now,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.pin,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('admin can delete everyone\'s message', () {
      final msg = Message(
        id: '3',
        conversationId: 'c1',
        senderId: 'user2',
        body: 'Hi',
        createdAt: now,
      );
      final actions = menuMessageActions(
        msg,
        me: 'user1',
        now: now,
        admin: true,
      );
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('own photo with empty body has no copy', () {
      final msg = Message(
        id: '4',
        conversationId: 'c1',
        senderId: 'user1',
        body: '',
        createdAt: now,
        attachmentPath: 'path/to/photo',
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('own text 7h old has no edit but deleteForEveryone', () {
      final msg = Message(
        id: '5',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now.subtract(const Duration(hours: 7)),
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('edit boundary: exactly 6h old has no edit', () {
      final msg = Message(
        id: '6',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now.subtract(const Duration(hours: 6)),
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('edit boundary: 6h-1s old has edit', () {
      final msg = Message(
        id: '7',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now.subtract(const Duration(hours: 6, seconds: -1)),
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('own forwarded message has no edit', () {
      final msg = Message(
        id: '8',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Forwarded',
        createdAt: now,
        forwarded: true,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });

    test('deleted placeholder own message gives only deleteForMe', () {
      final msg = Message(
        id: '9',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
        deletion: MessageDeletion.placeholder,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(actions, equals([MessageAction.deleteForMe]));
    });

    test('pending sending message has no actions', () {
      final msg = Message(
        id: '10',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
        sending: true,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(actions, equals([]));
    });

    test('pending local image message has no actions', () {
      final msg = Message(
        id: '11',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: now,
        localImage: Uint8List.fromList([1, 2, 3]),
      );
      final actions = menuMessageActions(msg, me: 'user1', now: now);
      expect(actions, equals([]));
    });

    test('me null: no edit, no deleteForEveryone', () {
      final msg = Message(
        id: '12',
        conversationId: 'c1',
        senderId: 'user2',
        body: 'Hi',
        createdAt: now,
      );
      final actions = menuMessageActions(msg, me: null, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.pin,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('createdAt and now as local times still allow edit', () {
      final utcNow = DateTime.utc(2026, 9, 24, 12);
      final localNow = utcNow.toLocal();
      final utcCreated = utcNow.subtract(const Duration(hours: 5));
      final localCreated = utcCreated.toLocal();

      final msg = Message(
        id: '13',
        conversationId: 'c1',
        senderId: 'user1',
        body: 'Hello',
        createdAt: localCreated,
      );
      final actions = menuMessageActions(msg, me: 'user1', now: localNow);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.copy,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.pin,
          MessageAction.deleteForMe,
          MessageAction.deleteForEveryone,
        ]),
      );
    });
  });
}

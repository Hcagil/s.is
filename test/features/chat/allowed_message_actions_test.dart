// allowedMessageActions, from the rules in docs/DECISIONS.md: reply and
// forward on any stored message; edit only on your own message younger than
// 6 hours (never a forwarded one); one Delete (the box decides "for everyone",
// 6 h rule) on your own message at
// any age and on anyone's (delete for me works on any message, rule 1);
// nothing on a pending message. Read-by left the action set in Update 1
// (reactions); slice 7 brings a readers card instead.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  final now = DateTime.utc(2026, 9, 28, 12);
  const me = 'u1';
  const other = 'u2';

  Message buildMessage({
    required String senderId,
    required DateTime createdAt,
    bool forwarded = false,
    String body = 'Hello',
    String? attachmentPath,
    Uint8List? localImage,
    MessageDeletion? deletion,
  }) {
    return Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: senderId,
      body: body,
      createdAt: createdAt,
      attachmentPath: attachmentPath,
      localImage: localImage,
      deletion: deletion,
      forwarded: forwarded,
    );
  }

  group('allowedMessageActions', () {
    test('Own stored text, age < 6h -> reply first, in any chat', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own stored photo with caption, age < 6h', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
        attachmentPath: 'c1/1.png',
        body: 'Caption',
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own stored photo with empty caption, age < 6h', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
        attachmentPath: 'c1/1.png',
        body: '',
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own age exactly 6h -> reply, forward, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own age 6h-1s -> reply, forward, edit, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(
          const Duration(hours: 5, minutes: 59, seconds: 59),
        ),
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own age 6h+1s -> reply, forward, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6, seconds: 1)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own age 3 days -> reply, forward, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(days: 3)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Own forwarded message, age < 6h -> reply, forward, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
        forwarded: true,
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Somebody else\'s stored message, age < 6h -> reply & forward', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('Somebody else\'s photo, age < 6h -> reply & forward', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 5)),
        attachmentPath: 'c1/1.png',
      );
      final actions = allowedMessageActions(msg, me: me, now: now);
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test(
      'Pending own photo (localImage set, no attachmentPath) -> empty list',
      () {
        final msg = buildMessage(
          senderId: me,
          createdAt: now.subtract(const Duration(hours: 1)),
          localImage: Uint8List.fromList([0]),
        );
        final actionsGroupFalse = allowedMessageActions(msg, me: me, now: now);
        final actionsGroupTrue = allowedMessageActions(msg, me: me, now: now);
        expect(actionsGroupFalse, equals([]));
        expect(actionsGroupTrue, equals([]));
      },
    );

    test('Deleted message (placeholder) -> Delete only', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 1)),
        deletion: MessageDeletion.placeholder,
      );
      final actionsGroupFalse = allowedMessageActions(msg, me: me, now: now);
      final actionsGroupTrue = allowedMessageActions(msg, me: me, now: now);
      // Delete for me works on any message (rule 1), a deleted one too.
      expect(actionsGroupFalse, equals([MessageAction.deleteForMe]));
      expect(actionsGroupTrue, equals([MessageAction.deleteForMe]));
    });

    test('Deleted message (vanished) from other user -> Delete only', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 1)),
        deletion: MessageDeletion.vanished,
      );
      final actionsGroupFalse = allowedMessageActions(msg, me: me, now: now);
      final actionsGroupTrue = allowedMessageActions(msg, me: me, now: now);
      // Delete for me works on any message (rule 1), a deleted one too.
      expect(actionsGroupFalse, equals([MessageAction.deleteForMe]));
      expect(actionsGroupTrue, equals([MessageAction.deleteForMe]));
    });

    test('me == null: fresh stored message -> no edit', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(minutes: 10)),
      );
      final actions = allowedMessageActions(msg, me: null, now: now);
      expect(actions, isNot(contains(MessageAction.edit)));
    });

    test('me == null: deleted message -> empty list', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(minutes: 10)),
        deletion: MessageDeletion.placeholder,
      );
      final actions = allowedMessageActions(msg, me: null, now: now);
      expect(actions, equals([MessageAction.deleteForMe]));
    });

    // Run under TZ=JST-9: the window is between instants, so a local and a
    // UTC reading of the same moments must agree.
    test('the 6 h edit window compares instants, not wall-clock fields', () {
      final fresh = buildMessage(
        senderId: me,
        createdAt: now
            .subtract(const Duration(hours: 5, minutes: 59))
            .toLocal(),
      );
      final stale = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6, minutes: 1)).toLocal(),
      );
      expect(
        allowedMessageActions(fresh, me: me, now: now),
        contains(MessageAction.deleteForMe),
      );
      expect(
        allowedMessageActions(fresh, me: me, now: now.toLocal()),
        contains(MessageAction.edit),
      );
      expect(
        allowedMessageActions(stale, me: me, now: now.toLocal()),
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.deleteForMe,
        ]),
      );
    });

    test('admin or not, another\'s old message gets the same one Delete', () {
      final theirs = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(days: 30)),
      );
      const row = [
        MessageAction.reply,
        MessageAction.forward,
        MessageAction.deleteForMe,
      ];
      expect(allowedMessageActions(theirs, me: me, now: now), equals(row));
      expect(
        allowedMessageActions(theirs, me: me, now: now, admin: true),
        equals(row),
        reason: 'never edit on another\'s; the box decides "for everyone"',
      );
    });
  });
}

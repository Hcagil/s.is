// allowedMessageActions, from the rules in docs/DECISIONS.md: reply and
// forward on any stored message; edit and delete for everyone only on your
// own message younger than 6 hours (never edit a forwarded one); read-by on
// your own message in a group; nothing on a pending or deleted message.
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
    test('Own stored text, age < 6h, group true -> all actions', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(
        actions,
        equals([
          MessageAction.readBy,
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.delete,
        ]),
      );
    });

    test('Own stored text, age < 6h, group false -> no readBy', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.delete,
        ]),
      );
    });

    test('Own stored photo with caption, age < 6h, group false', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
        attachmentPath: 'c1/1.png',
        body: 'Caption',
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.delete,
        ]),
      );
    });

    test('Own stored photo with empty caption, age < 6h, group false', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
        attachmentPath: 'c1/1.png',
        body: '',
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.delete,
        ]),
      );
    });

    test('Own age exactly 6h, group false -> reply & forward only', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6)),
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(actions, equals([MessageAction.reply, MessageAction.forward]));
    });

    test('Own age exactly 6h, group true -> readBy + reply & forward', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(
        actions,
        equals([
          MessageAction.readBy,
          MessageAction.reply,
          MessageAction.forward,
        ]),
      );
    });

    test('Own age 6h-1s, group false -> reply, forward, edit, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(
          const Duration(hours: 5, minutes: 59, seconds: 59),
        ),
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(
        actions,
        equals([
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.delete,
        ]),
      );
    });

    test('Own age 6h-1s, group true -> all actions', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(
          const Duration(hours: 5, minutes: 59, seconds: 59),
        ),
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(
        actions,
        equals([
          MessageAction.readBy,
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.edit,
          MessageAction.delete,
        ]),
      );
    });

    test('Own age 6h+1s, group false -> reply & forward only', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6, seconds: 1)),
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(actions, equals([MessageAction.reply, MessageAction.forward]));
    });

    test('Own age 6h+1s, group true -> readBy + reply & forward', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6, seconds: 1)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(
        actions,
        equals([
          MessageAction.readBy,
          MessageAction.reply,
          MessageAction.forward,
        ]),
      );
    });

    test('Own age 3 days, group false -> reply & forward only', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(days: 3)),
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(actions, equals([MessageAction.reply, MessageAction.forward]));
    });

    test('Own age 3 days, group true -> readBy + reply & forward', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(days: 3)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(
        actions,
        equals([
          MessageAction.readBy,
          MessageAction.reply,
          MessageAction.forward,
        ]),
      );
    });

    test(
      'Own forwarded message, age < 6h, group false -> reply, forward, delete',
      () {
        final msg = buildMessage(
          senderId: me,
          createdAt: now.subtract(const Duration(hours: 5)),
          forwarded: true,
        );
        final actions = allowedMessageActions(
          msg,
          me: me,
          now: now,
          group: false,
        );
        expect(
          actions,
          equals([
            MessageAction.reply,
            MessageAction.forward,
            MessageAction.delete,
          ]),
        );
      },
    );

    test('Own forwarded message, age < 6h, group true -> readBy, reply, forward, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 5)),
        forwarded: true,
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(
        actions,
        equals([
          MessageAction.readBy,
          MessageAction.reply,
          MessageAction.forward,
          MessageAction.delete,
        ]),
      );
    });

    test('Somebody else\'s stored message, age < 6h, group false -> reply & forward', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final actions = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      expect(actions, equals([MessageAction.reply, MessageAction.forward]));
    });

    test('Somebody else\'s stored message, age < 6h, group true -> reply & forward', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(actions, equals([MessageAction.reply, MessageAction.forward]));
    });

    test(
      'Somebody else\'s photo, age < 6h, group false -> reply & forward',
      () {
        final msg = buildMessage(
          senderId: other,
          createdAt: now.subtract(const Duration(hours: 5)),
          attachmentPath: 'c1/1.png',
        );
        final actions = allowedMessageActions(
          msg,
          me: me,
          now: now,
          group: false,
        );
        expect(actions, equals([MessageAction.reply, MessageAction.forward]));
      },
    );

    test('Somebody else\'s photo, age < 6h, group true -> reply & forward', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 5)),
        attachmentPath: 'c1/1.png',
      );
      final actions = allowedMessageActions(msg, me: me, now: now, group: true);
      expect(actions, equals([MessageAction.reply, MessageAction.forward]));
    });

    test(
      'Pending own photo (localImage set, no attachmentPath) -> empty list',
      () {
        final msg = buildMessage(
          senderId: me,
          createdAt: now.subtract(const Duration(hours: 1)),
          localImage: Uint8List.fromList([0]),
        );
        final actionsGroupFalse = allowedMessageActions(
          msg,
          me: me,
          now: now,
          group: false,
        );
        final actionsGroupTrue = allowedMessageActions(
          msg,
          me: me,
          now: now,
          group: true,
        );
        expect(actionsGroupFalse, equals([]));
        expect(actionsGroupTrue, equals([]));
      },
    );

    test('Deleted message (placeholder) -> empty list', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 1)),
        deletion: MessageDeletion.placeholder,
      );
      final actionsGroupFalse = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      final actionsGroupTrue = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: true,
      );
      expect(actionsGroupFalse, equals([]));
      expect(actionsGroupTrue, equals([]));
    });

    test('Deleted message (vanished) from other user -> empty list', () {
      final msg = buildMessage(
        senderId: other,
        createdAt: now.subtract(const Duration(hours: 1)),
        deletion: MessageDeletion.vanished,
      );
      final actionsGroupFalse = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: false,
      );
      final actionsGroupTrue = allowedMessageActions(
        msg,
        me: me,
        now: now,
        group: true,
      );
      expect(actionsGroupFalse, equals([]));
      expect(actionsGroupTrue, equals([]));
    });

    test('me == null: fresh stored message, group false -> no readBy, edit, delete', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(minutes: 10)),
      );
      final actions = allowedMessageActions(
        msg,
        me: null,
        now: now,
        group: false,
      );
      expect(actions, isNot(contains(MessageAction.readBy)));
      expect(actions, isNot(contains(MessageAction.edit)));
      expect(actions, isNot(contains(MessageAction.delete)));
    });

    test(
      'me == null: fresh stored message, group true -> no readBy, edit, delete',
      () {
        final msg = buildMessage(
          senderId: me,
          createdAt: now.subtract(const Duration(minutes: 10)),
        );
        final actions = allowedMessageActions(
          msg,
          me: null,
          now: now,
          group: true,
        );
        expect(actions, isNot(contains(MessageAction.readBy)));
        expect(actions, isNot(contains(MessageAction.edit)));
        expect(actions, isNot(contains(MessageAction.delete)));
      },
    );

    test('me == null: deleted message -> empty list', () {
      final msg = buildMessage(
        senderId: me,
        createdAt: now.subtract(const Duration(minutes: 10)),
        deletion: MessageDeletion.placeholder,
      );
      final actions = allowedMessageActions(
        msg,
        me: null,
        now: now,
        group: false,
      );
      expect(actions, equals([]));
    });

    // Run under TZ=JST-9: the window is between instants, so a local and a
    // UTC reading of the same moments must agree.
    test('the 6 h window compares instants, not wall-clock fields', () {
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
        contains(MessageAction.delete),
      );
      expect(
        allowedMessageActions(stale, me: me, now: now.toLocal()),
        equals([MessageAction.reply, MessageAction.forward]),
      );
    });
  });
}

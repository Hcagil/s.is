import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  group('isSendableBody mirrors the database constraint', () {
    test('rejects empty and whitespace-only bodies', () {
      expect(isSendableBody(''), isFalse);
      expect(isSendableBody('   '), isFalse);
      expect(isSendableBody('\n\t '), isFalse);
    });

    test('accepts a body with content, including surrounding space', () {
      expect(isSendableBody('hi'), isTrue);
      expect(isSendableBody('  hi  '), isTrue);
    });

    test('measures length after trimming, like btrim in the constraint', () {
      final exact = 'a' * maxMessageLength;
      expect(isSendableBody(exact), isTrue);
      expect(isSendableBody('  $exact  '), isTrue);
      expect(isSendableBody('a$exact'), isFalse);
    });
  });

  test('isFrom decides which side a message is drawn on', () {
    final m = Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'me',
      body: 'hello',
      createdAt: DateTime.utc(2026, 9, 22),
    );
    expect(m.isFrom('me'), isTrue);
    expect(m.isFrom('someone-else'), isFalse);
  });

  group('previewText', () {
    Message m({String body = '', String? path}) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'u1',
      body: body,
      createdAt: DateTime.utc(2026, 9, 22),
      attachmentPath: path,
    );

    test('a text message previews as its body', () {
      expect(previewText(m(body: 'see you')), 'see you');
    });

    test('an image with no caption previews as Photo', () {
      expect(previewText(m(path: 'c1/1.png')), 'Photo');
    });

    test('an image with a caption previews as the caption', () {
      expect(previewText(m(body: 'look', path: 'c1/1.png')), 'look');
    });
  });

  group('previewTime', () {
    // Built from local wall-clock values, so every expectation below holds in
    // any time zone the suite runs in. The two local-time tests can only tell
    // local from UTC where they differ: the container defaults to UTC, so run
    // them with `docker compose run --rm -e TZ=JST-9 flutter flutter test ...`
    // (a POSIX zone string; the image has no tzdata) to make them bite.
    final now = DateTime(2026, 9, 23, 15, 40);

    test('today shows the time of day, zero-padded', () {
      expect(previewTime(DateTime(2026, 9, 23, 9, 5), now), '09:05');
    });

    test('another day shows the date as dd.MM.yy', () {
      expect(previewTime(DateTime(2026, 9, 3, 9, 5), now), '03.09.26');
    });

    test('the same day and month of another year is not today', () {
      expect(previewTime(DateTime(2025, 9, 23, 9, 5), now), '23.09.25');
    });

    test('the same day of another month is not today', () {
      expect(previewTime(DateTime(2026, 8, 23, 9, 5), now), '23.08.26');
    });

    test('midnight is the boundary between the two formats', () {
      final justAfterMidnight = DateTime(2026, 9, 23, 0, 0, 30);
      expect(
        previewTime(DateTime(2026, 9, 22, 23, 59, 59), justAfterMidnight),
        '22.09.26',
        reason: 'one second before midnight is yesterday',
      );
      expect(previewTime(DateTime(2026, 9, 23), justAfterMidnight), '00:00');
      expect(
        previewTime(DateTime(2026, 9, 23, 23, 59), DateTime(2026, 9, 23)),
        '23:59',
        reason: 'the last minute of today is still today',
      );
    });

    test('a UTC timestamp is shown in local time', () {
      // Timestamps arrive from the server in UTC. The same instant, handed
      // over as UTC, must render exactly like its local form.
      final local = DateTime(2026, 9, 23, 9, 5);
      expect(previewTime(local.toUtc(), now), '09:05');
      expect(previewTime(local.toUtc(), now.toUtc()), '09:05');
    });

    test('"today" is decided in local time, not in UTC', () {
      // Local 00:30 and local 23:30 on the same local day. Wherever the zone
      // is not UTC, one of them falls on a different UTC date; a comparison
      // made in UTC then calls today's message yesterday's.
      final early = DateTime(2026, 9, 23, 0, 30);
      final late = DateTime(2026, 9, 23, 23, 30);
      expect(previewTime(early.toUtc(), late.toUtc()), '00:30');
      expect(previewTime(late.toUtc(), early.toUtc()), '23:30');
    });
  });

  group('canDeleteForEveryone', () {
    final now = DateTime.utc(2026, 9, 24, 12, 0);
    Message msg({
      String sender = 'me',
      Duration age = const Duration(minutes: 1),
      Uint8List? localImage,
      String? attachmentPath,
      MessageDeletion? deletion,
      bool sending = false,
    }) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: sender,
      body: 'hi',
      createdAt: now.subtract(age),
      localImage: localImage,
      attachmentPath: attachmentPath,
      deletion: deletion,
      sending: sending,
    );

    test('own, stored and undeleted: yes, at any age', () {
      for (final age in const [
        Duration(minutes: 1),
        Duration(hours: 6),
        Duration(hours: 7),
        Duration(days: 400),
      ]) {
        expect(
          msg(age: age).canDeleteForEveryone('me'),
          isTrue,
          reason: '$age',
        );
      }
    });

    test('somebody else\'s message: no, unless the caller is an admin', () {
      expect(msg(sender: 'other').canDeleteForEveryone('me'), isFalse);
      expect(
        msg(sender: 'other').canDeleteForEveryone('me', admin: false),
        isFalse,
      );
      expect(
        msg(
          sender: 'other',
          age: const Duration(days: 30),
        ).canDeleteForEveryone('me', admin: true),
        isTrue,
      );
    });

    test('already deleted: no, not even for an admin', () {
      for (final d in MessageDeletion.values) {
        expect(msg(deletion: d).canDeleteForEveryone('me'), isFalse);
        expect(
          msg(
            sender: 'other',
            deletion: d,
          ).canDeleteForEveryone('me', admin: true),
          isFalse,
        );
      }
    });

    test('still pending: no, not even for an admin', () {
      final photo = msg(localImage: Uint8List(0));
      expect(photo.isPending, isTrue);
      expect(photo.canDeleteForEveryone('me'), isFalse);
      expect(photo.canDeleteForEveryone('me', admin: true), isFalse);
      final text = msg(sending: true);
      expect(text.isPending, isTrue);
      expect(text.canDeleteForEveryone('me'), isFalse);
    });

    test('a stored photo message (local image AND a path): yes', () {
      final stored = msg(localImage: Uint8List(0), attachmentPath: 'c1/1.png');
      expect(stored.isPending, isFalse);
      expect(stored.canDeleteForEveryone('me'), isTrue);
    });
  });

  group('deletedByAdmin', () {
    Message m(String? by) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'u1',
      body: '',
      createdAt: DateTime.utc(2026, 9, 24),
      deletion: by == null ? null : MessageDeletion.placeholder,
      deletedBy: by,
    );

    test('deleted by somebody other than the sender: yes', () {
      expect(m('admin').deletedByAdmin, isTrue);
    });

    test('deleted by its sender, or not deleted: no', () {
      expect(m('u1').deletedByAdmin, isFalse);
      expect(m(null).deletedByAdmin, isFalse);
    });
  });

  group('menuMessageActions', () {
    final now = DateTime.utc(2026, 9, 24, 12, 0);
    const order = [
      MessageAction.reply,
      MessageAction.copy,
      MessageAction.forward,
      MessageAction.edit,
      MessageAction.pin,
      MessageAction.deleteForMe,
      MessageAction.deleteForEveryone,
    ];
    Message msg({
      String sender = 'me',
      String body = 'hi',
      Duration age = const Duration(minutes: 1),
      String? attachmentPath,
      Uint8List? localImage,
      MessageDeletion? deletion,
      bool sending = false,
      bool forwarded = false,
    }) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: sender,
      body: body,
      createdAt: now.subtract(age),
      attachmentPath: attachmentPath,
      localImage: localImage,
      deletion: deletion,
      sending: sending,
      forwarded: forwarded,
    );
    List<MessageAction> menu(Message m, {String? me = 'me'}) =>
        menuMessageActions(m, me: me, now: now);

    void inOrder(List<MessageAction> actions) {
      expect(actions.toSet().length, actions.length, reason: 'no repeats');
      expect(
        actions.every(order.contains),
        isTrue,
        reason: 'only the menu actions: $actions',
      );
      final idx = actions.map(order.indexOf).toList();
      expect(idx, [...idx]..sort(), reason: 'in menu order: $actions');
    }

    test('own fresh text: reply, copy, forward, edit, pin, both deletes -- in order', () {
      final a = menu(msg());
      expect(a, order);
    });

    test('copy only for a non-empty body', () {
      final photo = msg(body: '', attachmentPath: 'c1/1.png');
      final a = menu(photo);
      inOrder(a);
      expect(a, isNot(contains(MessageAction.copy)));
      expect(a, contains(MessageAction.deleteForEveryone));
      final captioned = menu(msg(body: 'look', attachmentPath: 'c1/1.png'));
      expect(captioned, contains(MessageAction.copy));
    });

    test('a deleted message offers only delete for me', () {
      // deletion keeps a body here on purpose: copy must be refused for
      // being deleted, not merely for being empty.
      final a = menu(msg(deletion: MessageDeletion.placeholder));
      inOrder(a);
      expect(a, isNot(contains(MessageAction.copy)));
      expect(a, isNot(contains(MessageAction.edit)));
      expect(a, [MessageAction.deleteForMe]);
    });

    test('a pending message offers neither copy nor delete', () {
      for (final pending in [
        msg(sending: true),
        msg(localImage: Uint8List(0)),
      ]) {
        expect(pending.isPending, isTrue);
        final a = menu(pending);
        inOrder(a);
        expect(a, isNot(contains(MessageAction.copy)));
        expect(a, isNot(contains(MessageAction.deleteForMe)));
        expect(a, isNot(contains(MessageAction.deleteForEveryone)));
        expect(a, isNot(contains(MessageAction.edit)));
      }
    });

    test(
      'somebody else\'s message: delete for me, never edit or for everyone',
      () {
        final a = menu(msg(sender: 'other'));
        inOrder(a);
        expect(a, contains(MessageAction.deleteForMe));
        expect(a, isNot(contains(MessageAction.deleteForEveryone)));
        expect(a, contains(MessageAction.copy));
        expect(a, isNot(contains(MessageAction.edit)));
      },
    );

    test('edit follows canEdit exactly', () {
      for (final m in [
        msg(),
        msg(age: const Duration(hours: 7)),
        msg(forwarded: true),
        msg(sender: 'other'),
      ]) {
        expect(
          menu(m).contains(MessageAction.edit),
          m.canEdit('me', now),
          reason: '${m.createdAt} forwarded=${m.forwarded} ${m.senderId}',
        );
      }
      expect(
        menu(msg(age: const Duration(hours: 7))),
        isNot(contains(MessageAction.edit)),
      );
      expect(
        menu(msg(age: const Duration(hours: 7))),
        contains(MessageAction.deleteForEveryone),
        reason: 'delete for everyone has no time limit (0.30.8)',
      );
    });

    test('canReact: a stored, undeleted message, anyone\'s, any age', () {
      expect(msg().canReact, isTrue);
      expect(msg(sender: 'other').canReact, isTrue);
      expect(msg(body: '', attachmentPath: 'c1/1.png').canReact, isTrue);
      expect(msg(age: const Duration(days: 30)).canReact, isTrue);
    });

    test('canReact: never on a pending or a deleted message', () {
      for (final m in [
        msg(sending: true),
        msg(localImage: Uint8List(0)),
        msg(deletion: MessageDeletion.placeholder),
        msg(sender: 'other', deletion: MessageDeletion.placeholder),
      ]) {
        expect(m.canReact, isFalse, reason: '$m');
      }
    });
  });

  test('withPreview replaces the preview and keeps who the chat is with', () {
    const bob = Member(userId: 'u2', displayName: 'Bob');
    const before = Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'old',
      lastMessageAt: null,
      lastSenderId: 'u1',
    );
    final at = DateTime.utc(2026, 9, 22, 12);
    final after = before.withPreview(
      Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u2',
        body: 'new',
        createdAt: at,
      ),
    );
    expect(after.id, 'c1');
    expect(after.other, bob);
    expect(after.title, isNull);
    expect(after.lastMessage, 'new');
    expect(after.lastMessageAt, at);
    expect(after.lastSenderId, 'u2');

    const group = Conversation(id: 'g1', title: 'Trip');
    final photo = group.withPreview(
      Message(
        id: 'm3',
        conversationId: 'g1',
        senderId: 'u2',
        body: '',
        createdAt: at,
        attachmentPath: 'g1/1.png',
      ),
    );
    expect(photo.title, 'Trip');
    expect(
      photo.lastMessage,
      'Photo',
      reason: 'a live image must preview like a re-read one, not as blank',
    );
  });
}

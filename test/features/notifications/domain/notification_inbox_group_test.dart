// addToInbox's server-separated sender/chat (0.30.6), from the contract:
// both present wins over the title; one alone or neither falls back to
// parsePushTitle.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/notification_inbox.dart';

void main() {
  group('addToInbox', () {
    const conversationId = 'conv-123';
    final at1 = DateTime.fromMillisecondsSinceEpoch(1000);
    final at2 = DateTime.fromMillisecondsSinceEpoch(2000);

    test('both sender and chat non-null: title ignored, group true', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'SIS',
        body: 'Hello',
        sender: 'Ava',
        chat: 'Team',
        at: at1,
      );

      expect(updated.length, 1);
      final chat = updated.first;
      expect(chat.title, 'Team');
      expect(chat.group, isTrue);
      expect(chat.count, 1);
      expect(chat.posted, 0);
      expect(chat.lines.length, 1);
      final line = chat.lines.first;
      expect(line.sender, 'Ava');
      expect(line.text, 'Hello');
      expect(line.at, at1.millisecondsSinceEpoch);
    });

    test('both sender and chat null: parsePushTitle used', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Ava @ Team',
        body: 'Hi',
        at: at1,
      );

      expect(updated.length, 1);
      final chat = updated.first;
      expect(chat.title, 'Team');
      expect(chat.group, isTrue);
      expect(chat.count, 1);
      expect(chat.lines.first.sender, 'Ava');
      expect(chat.lines.first.text, 'Hi');
    });

    test('only sender non-null: parsePushTitle used, sender ignored', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Ava',
        body: 'Hi',
        sender: 'Bob',
        at: at1,
      );

      expect(updated.first.title, 'Ava');
      expect(updated.first.group, isFalse);
      expect(updated.first.lines.first.sender, 'Ava');
    });

    test('only chat non-null: parsePushTitle used, chat ignored', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Ava',
        body: 'Hi',
        chat: 'Team',
        at: at1,
      );

      expect(updated.first.title, 'Ava');
      expect(updated.first.group, isFalse);
      expect(updated.first.lines.first.sender, 'Ava');
    });

    test('both fields set: a title naming another group is ignored', () {
      final updated = addToInbox(
        <InboxChat>[],
        conversationId: conversationId,
        title: 'Ava @ Other',
        body: 'Hi',
        sender: 'Ben',
        chat: 'Team',
        at: at1,
      );

      expect(updated.single.title, 'Team');
      expect(updated.single.lines.single.sender, 'Ben');
    });

    test('chat contains " @ ": title kept verbatim', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'SIS',
        body: 'Hello',
        sender: 'Ava',
        chat: 'Team @ Work',
        at: at1,
      );

      expect(updated.first.title, 'Team @ Work');
      expect(updated.first.lines.first.sender, 'Ava');
    });

    test('sender contains " @ ": sender kept verbatim', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Team',
        body: 'Hello',
        sender: 'A @ B',
        chat: 'Team',
        at: at1,
      );

      expect(updated.first.title, 'Team');
      expect(updated.first.lines.first.sender, 'A @ B');
    });

    test('successive group messages keep each sender, count increments', () {
      var inbox = <InboxChat>[];
      inbox = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Team',
        body: 'Hello',
        sender: 'Ava',
        chat: 'Team',
        at: at1,
      );
      inbox = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Team',
        body: 'Hi',
        sender: 'Ben',
        chat: 'Team',
        at: at2,
      );

      final chat = inbox.first;
      expect(chat.title, 'Team');
      expect(chat.group, isTrue);
      expect(chat.count, 2);
      expect(chat.lines.length, 2);
      expect(chat.lines[0].sender, 'Ava');
      expect(chat.lines[1].sender, 'Ben');
    });

    test('later message with sender/chat updates title and group', () {
      var inbox = <InboxChat>[];
      // First 1:1 style message
      inbox = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Alice',
        body: 'Hi',
        at: at1,
      );
      // Later group style message
      inbox = addToInbox(
        inbox,
        conversationId: conversationId,
        title: 'Alice',
        body: 'Hello',
        sender: 'Bob',
        chat: 'Team',
        at: at2,
      );

      final chat = inbox.first;
      expect(chat.title, 'Team');
      expect(chat.group, isTrue);
      expect(chat.count, 2);
      expect(chat.lines[0].sender, 'Alice');
      expect(chat.lines[1].sender, 'Bob');
    });

    test('a group keeps the newest 25 lines, each with its own sender', () {
      var inbox = <InboxChat>[];
      for (var i = 0; i < 30; i++) {
        inbox = addToInbox(
          inbox,
          conversationId: conversationId,
          title: 'SIS',
          body: 'm$i',
          sender: 'S$i',
          chat: 'Team',
          at: DateTime.fromMillisecondsSinceEpoch(i),
        );
      }

      final chat = inbox.single;
      expect(chat.count, 30);
      expect(chat.lines.map((l) => l.text), [
        for (var i = 5; i < 30; i++) 'm$i',
      ]);
      expect(chat.lines.map((l) => l.sender), [
        for (var i = 5; i < 30; i++) 'S$i',
      ]);
    });
  });
}

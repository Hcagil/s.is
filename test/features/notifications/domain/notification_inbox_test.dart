// Pure domain rules for the grouped-notification inbox, from the contract
// only: parsePushTitle, addToInbox (move to end, newest maxInboxLines kept,
// count/posted), removeFromInbox, dirtyChats, markPosted, inboxSummary and
// the JSON form including the pre-0.25.2 stored format.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/notification_inbox.dart';

void main() {
  // A moment given as milliseconds since the epoch, as InboxLine.at stores it.
  DateTime atMs(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  group('parsePushTitle', () {
    test('plain title', () {
      final result = parsePushTitle('Ava');
      expect(result.chat, 'Ava');
      expect(result.sender, 'Ava');
      expect(result.group, isFalse);
    });

    test('title with @ and spaces', () {
      final result = parsePushTitle('Ava @ Team');
      expect(result.chat, 'Team');
      expect(result.sender, 'Ava');
      expect(result.group, isTrue);
    });

    test('title with multiple @', () {
      final result = parsePushTitle('Ava @ Team @ Work');
      expect(result.chat, 'Team @ Work');
      expect(result.sender, 'Ava');
      expect(result.group, isTrue);
    });

    test('title with no spaces around @', () {
      final result = parsePushTitle('a@b');
      expect(result.chat, 'a@b');
      expect(result.sender, 'a@b');
      expect(result.group, isFalse);
    });
  });

  group('addToInbox', () {
    test('creates a new chat', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Ava @ Team',
        body: 'Hello',
        at: atMs(1000),
      );

      expect(updated.length, 1);
      final chat = updated.first;
      expect(chat.conversationId, 'c1');
      expect(chat.title, 'Team');
      expect(chat.group, isTrue);
      expect(chat.count, 1);
      expect(chat.posted, 0);
      expect(chat.lines.length, 1);
      final line = chat.lines.first;
      expect(line.sender, 'Ava');
      expect(line.text, 'Hello');
      expect(line.at, 1000);
    });

    test('appends to existing chat and moves it to the end', () {
      final existing = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [InboxLine(sender: 'Ava', text: 'Old', at: 500)],
        count: 1,
        posted: 0,
      );
      final inbox = [existing];
      final updated = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Ava @ Team',
        body: 'New',
        at: atMs(2000),
      );

      expect(updated.length, 1);
      final chat = updated.first;
      expect(chat.count, 2);
      expect(chat.lines.length, 2);
      expect(chat.lines[0].text, 'Old');
      expect(chat.lines[1].text, 'New');
      // Ensure original list unchanged
      expect(inbox.first.count, 1);
    });

    test('keeps only the newest maxInboxLines lines', () {
      var inbox = <InboxChat>[];
      final convId = 'c1';
      for (int i = 0; i < maxInboxLines + 3; i++) {
        inbox = addToInbox(
          inbox,
          conversationId: convId,
          title: 'Ava @ Team',
          body: 'Msg $i',
          at: atMs(i),
        );
      }
      final chat = inbox.first;
      expect(chat.lines.length, maxInboxLines);
      // The oldest three are dropped, never the newest.
      expect(
        [for (final l in chat.lines) l.text],
        [for (var i = 3; i < maxInboxLines + 3; i++) 'Msg $i'],
      );
      // count keeps every message, not only the lines still shown.
      expect(chat.count, maxInboxLines + 3);
    });

    test('the chat that just received a message moves to the end, the '
        'others keep their order', () {
      var inbox = <InboxChat>[];
      for (final id in ['c1', 'c2', 'c3']) {
        inbox = addToInbox(
          inbox,
          conversationId: id,
          title: 'Ava',
          body: 'hi',
          at: atMs(1),
        );
      }
      inbox = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Ava',
        body: 'ping',
        at: atMs(2),
      );
      expect([for (final c in inbox) c.conversationId], ['c2', 'c3', 'c1']);
      expect(inbox.last.count, 2);
      expect(inbox.first.count, 1);
    });

    test('a group message keeps its sender on the line and the group as the '
        'chat title; a 1:1 has the name for both', () {
      var inbox = addToInbox(
        const [],
        conversationId: 'g',
        title: 'Ava @ Team @ Work',
        body: 'x',
        at: atMs(5),
      );
      inbox = addToInbox(
        inbox,
        conversationId: 'd',
        title: 'Ben',
        body: 'y',
        at: atMs(6),
      );
      expect(inbox[0].title, 'Team @ Work');
      expect(inbox[0].group, isTrue);
      expect(inbox[0].lines.single.sender, 'Ava');
      expect(inbox[1].title, 'Ben');
      expect(inbox[1].group, isFalse);
      expect(inbox[1].lines.single.sender, 'Ben');
      expect(inbox[1].lines.single.at, 6);
    });

    test('keeps posted unchanged', () {
      final existing = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 1,
        posted: 5,
      );
      final inbox = [existing];
      final updated = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Ava @ Team',
        body: 'New',
        at: atMs(2000),
      );
      expect(updated.first.posted, 5);
    });

    test('updates group flag to latest title', () {
      final existing = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 1,
        posted: 0,
      );
      final inbox = [existing];
      final updated = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Ava',
        body: 'New',
        at: atMs(2000),
      );
      expect(updated.first.group, isFalse);
      expect(updated.first.title, 'Ava');
    });

    test('does not mutate the original list', () {
      final inbox = <InboxChat>[];
      final updated = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Ava @ Team',
        body: 'Hello',
        at: atMs(1000),
      );
      expect(inbox, isEmpty);
      expect(updated, isNot(same(inbox)));
    });
  });

  group('removeFromInbox', () {
    test('removes the specified chat', () {
      final chat1 = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 1,
        posted: 0,
      );
      final chat2 = InboxChat(
        conversationId: 'c2',
        title: 'Solo',
        group: false,
        lines: [],
        count: 1,
        posted: 0,
      );
      final inbox = [chat1, chat2];
      final updated = removeFromInbox(inbox, 'c1');
      expect(updated.length, 1);
      expect(updated.first.conversationId, 'c2');
    });

    test('unknown id leaves the inbox unchanged', () {
      final chat = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 1,
        posted: 0,
      );
      final inbox = [chat];
      final updated = removeFromInbox(inbox, 'unknown');
      expect(updated, equals(inbox));
      removeFromInbox(inbox, 'c1');
      expect(inbox, hasLength(1), reason: 'the input is not mutated');
    });
  });

  group('dirtyChats', () {
    test('returns chats where count != posted', () {
      final chat1 = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 3,
        posted: 1,
      );
      final chat2 = InboxChat(
        conversationId: 'c2',
        title: 'Solo',
        group: false,
        lines: [],
        count: 2,
        posted: 2,
      );
      final inbox = [chat1, chat2];
      final dirty = dirtyChats(inbox);
      expect(dirty.length, 1);
      expect(dirty.first.conversationId, 'c1');
    });

    test('keeps inbox order', () {
      var inbox = <InboxChat>[];
      for (final id in ['c1', 'c2', 'c3']) {
        inbox = addToInbox(
          inbox,
          conversationId: id,
          title: 'Ava',
          body: 'hi',
          at: atMs(1),
        );
      }
      expect(
        [for (final c in dirtyChats(inbox)) c.conversationId],
        ['c1', 'c2', 'c3'],
      );
    });
  });

  group('markPosted', () {
    test('sets posted to count for specified ids', () {
      final chat1 = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 3,
        posted: 0,
      );
      final chat2 = InboxChat(
        conversationId: 'c2',
        title: 'Solo',
        group: false,
        lines: [],
        count: 2,
        posted: 0,
      );
      final inbox = [chat1, chat2];
      final updated = markPosted(inbox, {'c1'});
      expect(updated[0].posted, 3);
      expect(updated[1].posted, 0);
    });

    test('does not affect other chats', () {
      final chat1 = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 3,
        posted: 0,
      );
      final chat2 = InboxChat(
        conversationId: 'c2',
        title: 'Solo',
        group: false,
        lines: [],
        count: 2,
        posted: 0,
      );
      final inbox = [chat1, chat2];
      final updated = markPosted(inbox, {'c1'});
      expect(updated[1].posted, 0);
    });

    test('dirtyChats excludes posted chats', () {
      final chat1 = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 3,
        posted: 3,
      );
      final chat2 = InboxChat(
        conversationId: 'c2',
        title: 'Solo',
        group: false,
        lines: [],
        count: 2,
        posted: 0,
      );
      final inbox = [chat1, chat2];
      final dirty = dirtyChats(inbox);
      expect(dirty.length, 1);
      expect(dirty.first.conversationId, 'c2');
    });

    test('adding to a posted chat makes it dirty again', () {
      final chat = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 3,
        posted: 3,
      );
      final inbox = [chat];
      final afterMark = markPosted(inbox, {'c1'});
      expect(dirtyChats(afterMark), isEmpty);
      final afterAdd = addToInbox(
        afterMark,
        conversationId: 'c1',
        title: 'Ava @ Team',
        body: 'New',
        at: atMs(2000),
      );
      expect(dirtyChats(afterAdd).first.conversationId, 'c1');
    });
  });

  group('inboxSummary', () {
    test('empty inbox', () {
      expect(inboxSummary([]), '');
    });

    test('one new message', () {
      final chat = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 1,
        posted: 0,
      );
      expect(inboxSummary([chat]), '1 new message');
    });

    test('multiple messages in one chat', () {
      final chat = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 3,
        posted: 0,
      );
      expect(inboxSummary([chat]), '3 new messages');
    });

    test('multiple chats', () {
      final chat1 = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [],
        count: 1,
        posted: 0,
      );
      final chat2 = InboxChat(
        conversationId: 'c2',
        title: 'Solo',
        group: false,
        lines: [],
        count: 2,
        posted: 0,
      );
      expect(inboxSummary([chat1, chat2]), '3 new messages from 2 chats');
      expect(
        inboxSummary([chat1, chat1, chat1]),
        '3 new messages from 3 chats',
      );
    });
  });

  group('JSON roundtrip', () {
    test('InboxChat toJson/fromJson roundtrip', () {
      final chat = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [
          InboxLine(sender: 'Ava', text: 'Hi', at: 1000),
          InboxLine(sender: 'Bob', text: 'Hello', at: 2000),
        ],
        count: 2,
        posted: 0,
      );
      final json = chat.toJson();
      final roundtrip = InboxChat.fromJson(json);
      expect(roundtrip.conversationId, chat.conversationId);
      expect(roundtrip.title, chat.title);
      expect(roundtrip.group, chat.group);
      expect(roundtrip.count, chat.count);
      expect(roundtrip.posted, chat.posted);
      expect(roundtrip.lines.length, chat.lines.length);
      for (var i = 0; i < chat.lines.length; i++) {
        expect(roundtrip.lines[i].sender, chat.lines[i].sender);
        expect(roundtrip.lines[i].text, chat.lines[i].text);
        expect(roundtrip.lines[i].at, chat.lines[i].at);
      }
    });

    test('InboxChat jsonEncode/jsonDecode roundtrip', () {
      final chat = InboxChat(
        conversationId: 'c1',
        title: 'Team',
        group: true,
        lines: [InboxLine(sender: 'Ava', text: 'Hi', at: 1000)],
        count: 1,
        posted: 0,
      );
      final encoded = jsonEncode(chat.toJson());
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      final roundtrip = InboxChat.fromJson(decoded);
      expect(roundtrip.conversationId, chat.conversationId);
      expect(roundtrip.title, chat.title);
      expect(roundtrip.group, chat.group);
      expect(roundtrip.count, chat.count);
      expect(roundtrip.posted, chat.posted);
      expect(roundtrip.lines.length, chat.lines.length);
      expect(roundtrip.lines.first.sender, 'Ava');
      expect(roundtrip.lines.first.text, 'Hi');
      expect(roundtrip.lines.first.at, 1000);
    });

    test('InboxChat fromJson legacy format', () {
      final legacy = {
        'c': 'c-old',
        't': 'Olga',
        'l': ['legacy one', 'legacy two'],
        'n': 2,
      };
      final chat = InboxChat.fromJson(legacy);
      expect(chat.conversationId, 'c-old');
      expect(chat.title, 'Olga');
      expect(chat.group, isFalse);
      expect(chat.count, 2);
      expect(chat.posted, 2);
      expect(chat.lines.length, 2);
      expect(chat.lines[0].sender, '');
      expect(chat.lines[0].text, 'legacy one');
      expect(chat.lines[0].at, 0);
      expect(chat.lines[1].sender, '');
      expect(chat.lines[1].text, 'legacy two');
      expect(chat.lines[1].at, 0);
    });
  });
}

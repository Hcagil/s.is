// Pure domain rules for the grouped-notification inbox, written from the
// contract in lib/features/notifications/domain/notification_inbox.dart:
// addToInbox moves a chat to the end with its latest title, appends the body
// keeping only the newest maxInboxLines, and counts one more; removeFromInbox
// drops a chat; inboxSummary words the total; InboxChat round-trips to JSON.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/notification_inbox.dart';

InboxChat chat(
  String id, {
  String title = 'Maya',
  List<String> lines = const ['hi'],
  int count = 1,
}) => InboxChat(conversationId: id, title: title, lines: lines, count: count);

void main() {
  group('addToInbox', () {
    test('a new chat starts with count 1 and its one line', () {
      final result = addToInbox(
        const [],
        conversationId: 'c1',
        title: 'Maya',
        body: 'hi',
      );

      expect(result, hasLength(1));
      expect(result.single.conversationId, 'c1');
      expect(result.single.title, 'Maya');
      expect(result.single.lines, ['hi']);
      expect(result.single.count, 1);
    });

    test('does not mutate the list it was given', () {
      final input = [
        chat('c1', lines: const ['hi'], count: 1),
      ];
      final before = List.of(input);

      addToInbox(input, conversationId: 'c1', title: 'Maya', body: 'again');

      expect(input, hasLength(before.length));
      expect(input.single.lines, before.single.lines);
      expect(input.single.count, before.single.count);
    });

    test('a second message for the same chat appends its body, keeps the '
        'newest title and counts one more', () {
      final inbox = [
        chat('c1', title: 'Maya', lines: const ['hi'], count: 1),
      ];

      final result = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Maya (renamed)',
        body: 'you there?',
      );

      expect(result, hasLength(1));
      final updated = result.single;
      expect(updated.title, 'Maya (renamed)');
      expect(updated.lines, ['hi', 'you there?']);
      expect(updated.count, 2);
    });

    test('the chat that just received a message moves to the end', () {
      final inbox = [chat('c1'), chat('c2')];

      final result = addToInbox(
        inbox,
        conversationId: 'c1',
        title: 'Maya',
        body: 'ping',
      );

      expect([for (final c in result) c.conversationId], ['c2', 'c1']);
    });

    test('only the newest maxInboxLines are kept, oldest first', () {
      // Well past the cap, so a count that follows the kept lines (at most
      // maxInboxLines + 1 on any one step) cannot pass for the real count.
      const total = maxInboxLines + 3;
      var inbox = const <InboxChat>[];
      for (var i = 1; i <= total; i++) {
        inbox = addToInbox(
          inbox,
          conversationId: 'c1',
          title: 'Maya',
          body: 'line $i',
        );
      }

      expect(inbox.single.lines, hasLength(maxInboxLines));
      expect(inbox.single.lines, [
        for (var i = total - maxInboxLines + 1; i <= total; i++) 'line $i',
      ], reason: 'the oldest line must be dropped, not the newest');
      // count keeps every message ever received, even ones no longer shown.
      expect(inbox.single.count, total);
    });
  });

  group('removeFromInbox', () {
    test('drops the given chat and leaves the others untouched', () {
      final inbox = [chat('c1'), chat('c2')];

      final result = removeFromInbox(inbox, 'c1');

      expect([for (final c in result) c.conversationId], ['c2']);
    });

    test('does not mutate the list it was given', () {
      final inbox = [chat('c1'), chat('c2')];

      removeFromInbox(inbox, 'c1');

      expect([for (final c in inbox) c.conversationId], ['c1', 'c2']);
    });

    test('a chat not in the inbox leaves it unchanged', () {
      final inbox = [chat('c1')];

      final result = removeFromInbox(inbox, 'does-not-exist');

      expect([for (final c in result) c.conversationId], ['c1']);
    });
  });

  group('inboxSummary', () {
    test('an empty inbox is the empty string', () {
      expect(inboxSummary(const []), '');
    });

    test('one message in one chat', () {
      expect(inboxSummary([chat('c1', count: 1)]), '1 new message');
    });

    test('several messages in one chat: plural, no chat count', () {
      expect(inboxSummary([chat('c1', count: 3)]), '3 new messages');
    });

    test('messages spread over several chats names the chat count', () {
      final inbox = [chat('c1', count: 1), chat('c2', count: 2)];

      expect(inboxSummary(inbox), '3 new messages in 2 chats');
    });

    test('one message each in two chats is still plural, "in 2 chats"', () {
      final inbox = [chat('c1', count: 1), chat('c2', count: 1)];

      expect(inboxSummary(inbox), '2 new messages in 2 chats');
    });
  });

  group('InboxChat JSON', () {
    test('round-trips every field', () {
      const original = InboxChat(
        conversationId: 'c1',
        title: 'Maya',
        lines: ['hi', 'you there?'],
        count: 2,
      );

      final restored = InboxChat.fromJson(original.toJson());

      expect(restored.conversationId, original.conversationId);
      expect(restored.title, original.title);
      expect(restored.lines, original.lines);
      expect(restored.count, original.count);
    });

    test('round-trips through the JSON text it is stored as', () {
      // Stored as a string in shared preferences, so fromJson meets what
      // jsonDecode returns (List<dynamic>, Map<String, dynamic>), not the
      // typed map toJson built.
      const original = InboxChat(
        conversationId: 'c1',
        title: 'Maya',
        lines: ['hi', 'you there?'],
        count: 2,
      );

      final decoded = jsonDecode(jsonEncode(original.toJson()));
      final restored = InboxChat.fromJson(decoded as Map<String, Object?>);

      expect(restored.conversationId, 'c1');
      expect(restored.title, 'Maya');
      expect(restored.lines, ['hi', 'you there?']);
      expect(restored.count, 2);
    });

    test('round-trips an empty lines list', () {
      const original = InboxChat(
        conversationId: 'c1',
        title: 'Maya',
        lines: [],
        count: 0,
      );

      final restored = InboxChat.fromJson(original.toJson());

      expect(restored.lines, isEmpty);
    });
  });
}

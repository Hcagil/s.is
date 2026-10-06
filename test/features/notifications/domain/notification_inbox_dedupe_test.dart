import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/notification_inbox.dart';

void main() {
  const int epoch = 1000;
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(epoch);

  // Helper constructors
  InboxLine createLine(String sender, String text, int at, [String? id]) =>
      InboxLine(sender: sender, text: text, at: at, id: id);

  InboxChat createChat(
    String conversationId,
    String title,
    bool group,
    List<InboxLine> lines,
    int count,
    int posted,
  ) => InboxChat(
    conversationId: conversationId,
    title: title,
    group: group,
    lines: lines,
    count: count,
    posted: posted,
  );

  group('addToInbox dedupe', () {
    test('same messageId for same conversation does not change inbox', () {
      List<InboxChat> inbox = [];
      // First add to A
      inbox = addToInbox(
        inbox,
        conversationId: 'A',
        title: 'Chat A',
        body: 'Hello',
        sender: 'Alice',
        chat: 'Chat A',
        messageId: 'm1',
        at: at,
      );
      expect(inbox.length, 1);
      final chatA = inbox[0];
      expect(chatA.conversationId, 'A');
      expect(chatA.title, 'Chat A');
      expect(chatA.lines.length, 1);
      expect(chatA.lines[0].id, 'm1');
      expect(chatA.lines[0].sender, 'Alice');
      expect(chatA.lines[0].text, 'Hello');
      expect(chatA.count, 1);
      final postedBefore = chatA.posted;

      // Add to B
      inbox = addToInbox(
        inbox,
        conversationId: 'B',
        title: 'Chat B',
        body: 'Hello',
        sender: 'Bob',
        chat: 'Chat B',
        messageId: 'm2',
        at: at,
      );
      expect(inbox.length, 2);
      expect(inbox[0].conversationId, 'A');
      expect(inbox[1].conversationId, 'B');

      // Re‑add same messageId to A
      inbox = addToInbox(
        inbox,
        conversationId: 'A',
        title: 'Chat A',
        body: 'Hello again',
        sender: 'Alice',
        chat: 'Chat A',
        messageId: 'm1',
        at: at,
      );
      expect(inbox.length, 2);
      expect(inbox[0].conversationId, 'A');
      expect(inbox[1].conversationId, 'B');

      final chatA2 = inbox[0];
      expect(chatA2.count, 1);
      expect(chatA2.lines.length, 1);
      expect(chatA2.lines[0].id, 'm1');
      expect(chatA2.lines[0].sender, 'Alice');
      expect(chatA2.lines[0].text, 'Hello'); // unchanged
      expect(chatA2.posted, postedBefore);
    });

    test('re‑adding same id for chat with posted=1, count=1 keeps values', () {
      final line = createLine('Alice', 'Hi', epoch, 'm1');
      final chatC = createChat('C', 'Chat C', false, [line], 1, 1);
      List<InboxChat> inbox = [chatC];

      inbox = addToInbox(
        inbox,
        conversationId: 'C',
        title: 'Chat C',
        body: 'Hi again',
        sender: 'Alice',
        chat: 'Chat C',
        messageId: 'm1',
        at: at,
      );
      expect(inbox.length, 1);
      final chatC2 = inbox[0];
      expect(chatC2.count, 1);
      expect(chatC2.lines.length, 1);
      expect(chatC2.lines[0].id, 'm1');
      expect(chatC2.posted, 1);
    });

    test(
      'different messageId for same chat adds normally and moves chat to end',
      () {
        List<InboxChat> inbox = [];
        // A with m1
        inbox = addToInbox(
          inbox,
          conversationId: 'A',
          title: 'Chat A',
          body: 'Hello',
          sender: 'Alice',
          chat: 'Chat A',
          messageId: 'm1',
          at: at,
        );
        // B with m2
        inbox = addToInbox(
          inbox,
          conversationId: 'B',
          title: 'Chat B',
          body: 'Hello',
          sender: 'Bob',
          chat: 'Chat B',
          messageId: 'm2',
          at: at,
        );
        // A again with m3
        inbox = addToInbox(
          inbox,
          conversationId: 'A',
          title: 'Chat A',
          body: 'Hello again',
          sender: 'Alice',
          chat: 'Chat A',
          messageId: 'm3',
          at: at,
        );
        expect(inbox.length, 2);
        // Order should be B, A
        expect(inbox[0].conversationId, 'B');
        expect(inbox[1].conversationId, 'A');

        final chatA = inbox[1];
        expect(chatA.count, 2);
        expect(chatA.lines.length, 2);
        expect(chatA.lines[1].id, 'm3');
        expect(chatA.lines[1].text, 'Hello again');

        final chatB = inbox[0];
        expect(chatB.count, 1);
        expect(chatB.lines.length, 1);
      },
    );

    test('two adds with null messageId store separate lines', () {
      List<InboxChat> inbox = [];
      // First add with null id
      inbox = addToInbox(
        inbox,
        conversationId: 'A',
        title: 'Chat A',
        body: 'Hello',
        sender: 'Alice',
        chat: 'Chat A',
        messageId: null,
        at: at,
      );
      // Second add with null id
      inbox = addToInbox(
        inbox,
        conversationId: 'A',
        title: 'Chat A',
        body: 'Hello again',
        sender: 'Alice',
        chat: 'Chat A',
        messageId: null,
        at: at,
      );
      expect(inbox.length, 1);
      final chatA = inbox[0];
      expect(chatA.count, 2);
      expect(chatA.lines.length, 2);
      expect(chatA.lines[0].id, isNull);
      expect(chatA.lines[1].id, isNull);
    });

    test('addToInbox stores messageId on new line', () {
      List<InboxChat> inbox = [];
      inbox = addToInbox(
        inbox,
        conversationId: 'A',
        title: 'Chat A',
        body: 'Hello',
        sender: 'Alice',
        chat: 'Chat A',
        messageId: 'm1',
        at: at,
      );
      expect(inbox[0].lines.last.id, 'm1');
    });
  });

  group('InboxLine JSON round‑trip', () {
    test('id present in toJson and round‑trips', () {
      final line = InboxLine(sender: 'Ava', text: 'hi', at: 5, id: 'm1');
      final json = line.toJson();
      expect(json['m'], equals('m1'));
      expect(json['s'], equals('Ava'));
      expect(json['x'], equals('hi'));
      expect(json['a'], equals(5));

      final decoded = jsonDecode(jsonEncode(json));
      final line2 = InboxLine.fromJson(decoded);
      expect(line2.id, equals('m1'));
      expect(line2.sender, equals('Ava'));
      expect(line2.text, equals('hi'));
      expect(line2.at, equals(5));
    });

    test('id null omitted from toJson', () {
      final line = InboxLine(sender: 'Ava', text: 'hi', at: 5, id: null);
      final json = line.toJson();
      expect(json.containsKey('m'), isFalse);
    });

    test('old JSON without m key yields id null', () {
      final oldJson = {'s': 'Ava', 'x': 'hi', 'a': 5};
      final line = InboxLine.fromJson(oldJson);
      expect(line.id, isNull);
      expect(line.sender, equals('Ava'));
      expect(line.text, equals('hi'));
      expect(line.at, equals(5));
    });

    test('InboxChat.fromJson retains line ids', () {
      final chatJson = {
        'c': 'C',
        't': 'Chat C',
        'g': false,
        'l': [
          {'s': 'Ava', 'x': 'hi', 'a': 5, 'm': 'm1'},
        ],
        'n': 1,
        'p': 1,
      };
      final chat = InboxChat.fromJson(chatJson);
      expect(chat.lines.length, 1);
      final line = chat.lines[0];
      expect(line.id, equals('m1'));
      expect(line.sender, equals('Ava'));
      expect(line.text, equals('hi'));
      expect(line.at, equals(5));
    });
  });
}

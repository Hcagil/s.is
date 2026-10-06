import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/notification_action.dart';

void main() {
  group('ActionTicket', () {
    const validToken = 'token123';
    const validUrl = 'https://example.com';

    test('fromPush returns null when keys are missing', () {
      expect(ActionTicket.fromPush({'action_token': validToken}), isNull);
      expect(ActionTicket.fromPush({'action_url': validUrl}), isNull);
      expect(ActionTicket.fromPush({}), isNull);
    });

    test('fromPush returns null when keys are not strings or empty', () {
      expect(
        ActionTicket.fromPush({'action_token': 123, 'action_url': validUrl}),
        isNull,
      );
      expect(
        ActionTicket.fromPush({'action_token': validToken, 'action_url': 456}),
        isNull,
      );
      expect(
        ActionTicket.fromPush({'action_token': '', 'action_url': validUrl}),
        isNull,
      );
      expect(
        ActionTicket.fromPush({'action_token': validToken, 'action_url': ''}),
        isNull,
      );
    });

    test('fromPush returns ticket when both keys are valid', () {
      final ticket = ActionTicket.fromPush({
        'action_token': validToken,
        'action_url': validUrl,
      });
      expect(ticket, isNotNull);
      expect(ticket!.token, equals(validToken));
      expect(ticket.url, equals(validUrl));
    });

    test('fromPush ignores extra keys', () {
      final ticket = ActionTicket.fromPush({
        'action_token': validToken,
        'action_url': validUrl,
        'extra': 'ignored',
      });
      expect(ticket, isNotNull);
      expect(ticket!.token, equals(validToken));
      expect(ticket.url, equals(validUrl));
    });

    test('toJson produces correct map', () {
      final ticket = ActionTicket(token: validToken, url: validUrl);
      expect(ticket.toJson(), equals({'t': validToken, 'u': validUrl}));
    });

    test('fromJson returns null for invalid inputs', () {
      final invalidInputs = [
        null,
        42,
        'str',
        [],
        {},
        {'t': 'x'},
        {'u': 'y'},
        {'t': 1, 'u': 2},
        {'t': '', 'u': ''},
      ];
      for (final input in invalidInputs) {
        expect(
          ActionTicket.fromJson(input),
          isNull,
          reason: 'Input: $input should be null',
        );
      }
    });

    test('fromJson returns ticket for valid map', () {
      final map = {'t': validToken, 'u': validUrl};
      final ticket = ActionTicket.fromJson(map);
      expect(ticket, isNotNull);
      expect(ticket!.token, equals(validToken));
      expect(ticket.url, equals(validUrl));
    });

    test('round-trip via toJson -> fromJson', () {
      final ticket = ActionTicket(token: validToken, url: validUrl);
      final json = ticket.toJson();
      final roundTrip = ActionTicket.fromJson(json);
      expect(roundTrip, isNotNull);
      expect(roundTrip!.token, equals(validToken));
      expect(roundTrip.url, equals(validUrl));
    });

    test('round-trip via jsonEncode/jsonDecode', () {
      final ticket = ActionTicket(token: validToken, url: validUrl);
      final encoded = jsonEncode(ticket.toJson());
      final decoded = jsonDecode(encoded);
      final roundTrip = ActionTicket.fromJson(decoded);
      expect(roundTrip, isNotNull);
      expect(roundTrip!.token, equals(validToken));
      expect(roundTrip.url, equals(validUrl));
    });
  });

  group('NotificationAction', () {
    const conversationId = 'conv123';
    const token = 'token123';
    const url = 'https://example.com';
    final ticket = ActionTicket(token: token, url: url);

    test('fromResponse returns null for unknown actionId', () {
      expect(
        NotificationAction.fromResponse(
          actionId: 'sis.delete',
          conversationId: conversationId,
          ticket: ticket,
          input: 'hello',
          newId: () => 'ignored',
        ),
        isNull,
      );
      expect(
        NotificationAction.fromResponse(
          actionId: '',
          conversationId: conversationId,
          ticket: ticket,
          input: 'hello',
          newId: () => 'ignored',
        ),
        isNull,
      );
      expect(
        NotificationAction.fromResponse(
          actionId: null,
          conversationId: conversationId,
          ticket: ticket,
          input: 'hello',
          newId: () => 'ignored',
        ),
        isNull,
      );
    });

    test('fromResponse returns null for null or empty conversationId', () {
      expect(
        NotificationAction.fromResponse(
          actionId: markReadActionId,
          conversationId: null,
          ticket: ticket,
          input: null,
          newId: () => 'ignored',
        ),
        isNull,
      );
      expect(
        NotificationAction.fromResponse(
          actionId: markReadActionId,
          conversationId: '',
          ticket: ticket,
          input: null,
          newId: () => 'ignored',
        ),
        isNull,
      );
    });

    test('fromResponse returns null for null ticket', () {
      expect(
        NotificationAction.fromResponse(
          actionId: markReadActionId,
          conversationId: conversationId,
          ticket: null,
          input: null,
          newId: () => 'ignored',
        ),
        isNull,
      );
    });

    test('fromResponse returns null for reply with null input', () {
      expect(
        NotificationAction.fromResponse(
          actionId: replyActionId,
          conversationId: conversationId,
          ticket: ticket,
          input: null,
          newId: () => 'ignored',
        ),
        isNull,
      );
    });

    test('fromResponse returns null for reply with blank input', () {
      const blanks = [' ', '   ', '\n\t'];
      for (final blank in blanks) {
        expect(
          NotificationAction.fromResponse(
            actionId: replyActionId,
            conversationId: conversationId,
            ticket: ticket,
            input: blank,
            newId: () => 'ignored',
          ),
          isNull,
          reason: 'Input "$blank" should be considered blank',
        );
      }
    });

    test('fromResponse returns null for reply longer than 4000 chars', () {
      final longInput = 'x' * 4001;
      expect(
        NotificationAction.fromResponse(
          actionId: replyActionId,
          conversationId: conversationId,
          ticket: ticket,
          input: longInput,
          newId: () => 'ignored',
        ),
        isNull,
      );
    });

    test('fromResponse accepts reply of exactly 4000 chars', () {
      final input = 'x' * 4000;
      final action = NotificationAction.fromResponse(
        actionId: replyActionId,
        conversationId: conversationId,
        ticket: ticket,
        input: input,
        newId: () => 'msg123',
      );
      expect(action, isNotNull);
      expect(action!.kind, equals(NotificationActionKind.reply));
      expect(action.text, equals(input));
      expect(action.messageId, equals('msg123'));
    });

    test('fromResponse accepts reply of 1 char', () {
      final action = NotificationAction.fromResponse(
        actionId: replyActionId,
        conversationId: conversationId,
        ticket: ticket,
        input: 'a',
        newId: () => 'msg123',
      );
      expect(action, isNotNull);
      expect(action!.kind, equals(NotificationActionKind.reply));
      expect(action.text, equals('a'));
      expect(action.messageId, equals('msg123'));
    });

    test('fromResponse returns markRead correctly', () {
      int newIdCalls = 0;
      final action = NotificationAction.fromResponse(
        actionId: markReadActionId,
        conversationId: conversationId,
        ticket: ticket,
        input: null,
        newId: () {
          newIdCalls++;
          return 'ignored';
        },
      );
      expect(action, isNotNull);
      expect(action!.kind, equals(NotificationActionKind.markRead));
      expect(action.text, isNull);
      expect(action.messageId, isNull);
      expect(newIdCalls, equals(0));
    });

    test('newId called exactly once for valid reply', () {
      int newIdCalls = 0;
      final action = NotificationAction.fromResponse(
        actionId: replyActionId,
        conversationId: conversationId,
        ticket: ticket,
        input: 'hello',
        newId: () {
          newIdCalls++;
          return 'msg123';
        },
      );
      expect(action, isNotNull);
      expect(action!.messageId, equals('msg123'));
      expect(newIdCalls, equals(1));
    });

    test('newId not called for invalid reply', () {
      int newIdCalls = 0;
      final action = NotificationAction.fromResponse(
        actionId: replyActionId,
        conversationId: conversationId,
        ticket: ticket,
        input: '   ',
        newId: () {
          newIdCalls++;
          return 'ignored';
        },
      );
      expect(action, isNull);
      expect(newIdCalls, equals(0));
    });

    test('toRequest for markRead', () {
      final action = NotificationAction.fromResponse(
        actionId: markReadActionId,
        conversationId: conversationId,
        ticket: ticket,
        newId: () => 'unused',
      )!;
      final request = action.toRequest();
      expect(
        request,
        equals({
          'token': token,
          'conversation_id': conversationId,
          'action': 'mark_read',
        }),
      );
      expect(request.containsKey('id'), isFalse);
      expect(request.containsKey('body'), isFalse);
    });

    test('toRequest for reply', () {
      final action = NotificationAction.fromResponse(
        actionId: replyActionId,
        conversationId: conversationId,
        ticket: ticket,
        input: 'Hello',
        newId: () => 'msg123',
      )!;
      final request = action.toRequest();
      expect(
        request,
        equals({
          'token': token,
          'conversation_id': conversationId,
          'action': 'reply',
          'id': 'msg123',
          'body': 'Hello',
        }),
      );
    });
  });

  group('NotificationActionLabels', () {
    test('English labels', () {
      final labels = notificationActionLabels('en');
      expect(labels.markRead, equals('Mark as read'));
      expect(labels.reply, equals('Reply'));
      expect(labels.replyHint, isNotEmpty);
      expect(labels.notSent, isNotEmpty);
    });

    test('Turkish labels are non-empty and differ from English', () {
      final en = notificationActionLabels('en');
      final tr = notificationActionLabels('tr');
      expect(tr.markRead, isNotEmpty);
      expect(tr.reply, isNotEmpty);
      expect(tr.replyHint, isNotEmpty);
      expect(tr.notSent, isNotEmpty);
      expect(tr.markRead, isNot(equals(en.markRead)));
      expect(tr.reply, isNot(equals(en.reply)));
      expect(tr.replyHint, isNot(equals(en.replyHint)));
      expect(tr.notSent, isNot(equals(en.notSent)));
    });

    test('Unknown language falls back to English', () {
      final en = notificationActionLabels('en');
      final de = notificationActionLabels('de');
      expect(de.markRead, equals(en.markRead));
      expect(de.reply, equals(en.reply));
      expect(de.replyHint, equals(en.replyHint));
      expect(de.notSent, equals(en.notSent));
    });
  });
}

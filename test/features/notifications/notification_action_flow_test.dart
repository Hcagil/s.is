// The Mark as read / Reply buttons on Android, from the push that carried the
// ticket to the tap in the background isolate: LocalPushDisplay.show stores
// the push's ticket per chat (prefs key sis.push_actions), the button's
// isolate (a fresh SharedPreferences, as a new isolate has) finds it with
// ticketFor, onNotificationAction sends it -- once more on retry, with the
// SAME reply id -- and afterAction updates the shade.
//
// Stood in for: the notification shade and the prefs file (support/
// push_platform.dart), and the network (package:http's runWithClient), which
// answers each POST from a script: late failures, refusals, success.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/notification_action_background.dart';
import 'package:sis/features/notifications/domain/notification_action.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _chat = '7d5c9e2a-1b3f-4c8d-9e0a-112233445566';
const _other = '9f9f9f9f-1b3f-4c8d-9e0a-112233445566';
const _ticket = ActionTicket(
  token: 'v1.ticket-for-chat.sig',
  url: 'https://project.example/functions/v1/notification-action',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;

  void newIsolate() => SharedPreferences.resetStatic();

  Future<Object?> plugin(MethodCall call) async {
    if (call.method == 'areNotificationsEnabled') return true;
    return shade.handle(call);
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    LocalPushDisplay.resetForTest();
    shade = Shade();
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    newIsolate();
    await LocalPushDisplay.init();
    await LocalPushDisplay.forUser('member-a');
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
  });

  Future<void> pushArrives({
    String chat = _chat,
    ActionTicket? ticket = _ticket,
  }) => LocalPushDisplay.show(
    conversationId: chat,
    title: 'Bob',
    body: 'are you coming?',
    ticket: ticket,
  );

  /// Taps [actionId] on [chat]'s notification in a fresh isolate; the network
  /// answers each POST with the next of [statuses] (a null entry: no answer,
  /// the connection fails). Returns every request body the server received.
  Future<List<Map<String, Object?>>> tap(
    String actionId, {
    String chat = _chat,
    String? input,
    List<int?> statuses = const [200],
  }) async {
    newIsolate();
    final bodies = <Map<String, Object?>>[];
    final client = MockClient((req) async {
      expect(req.url.toString(), _ticket.url);
      bodies.add(Map<String, Object?>.from(jsonDecode(req.body) as Map));
      final i = bodies.length - 1;
      final status = i < statuses.length ? statuses[i] : 200;
      if (status == null) throw http.ClientException('connection reset');
      return http.Response('', status);
    });
    await http.runWithClient(
      () => onNotificationAction(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          id: 1,
          actionId: actionId,
          input: input,
          payload: chat,
        ),
      ),
      () => client,
    );
    return bodies;
  }

  group('the ticket a push carried', () {
    test('is stored per chat on disk and found by a fresh isolate', () async {
      await pushArrives();
      expect(disk.values.keys, contains('flutter.sis.push_actions'));
      newIsolate();
      final found = await LocalPushDisplay.ticketFor(_chat);
      expect([found?.token, found?.url], [_ticket.token, _ticket.url]);
      expect(await LocalPushDisplay.ticketFor(_other), isNull);
    });

    test(
      'a newer push replaces the chat\'s ticket; other chats keep theirs',
      () async {
        const second = ActionTicket(
          token: 'v1.newer.sig',
          url: 'https://project.example/x',
        );
        const otherTicket = ActionTicket(
          token: 'v1.other.sig',
          url: 'https://project.example/y',
        );
        await pushArrives();
        await pushArrives(chat: _other, ticket: otherTicket);
        await pushArrives(ticket: second);
        newIsolate();
        expect((await LocalPushDisplay.ticketFor(_chat))?.token, second.token);
        expect(
          (await LocalPushDisplay.ticketFor(_other))?.token,
          otherTicket.token,
        );
      },
    );
  });

  group('onNotificationAction', () {
    test(
      'Mark as read sends mark_read with the chat\'s ticket, once',
      () async {
        await pushArrives();
        final sent = await tap(markReadActionId);
        expect(sent, [
          {
            'token': _ticket.token,
            'conversation_id': _chat,
            'action': 'mark_read',
          },
        ]);
      },
    );

    test('Reply sends the text with a fresh uuid id', () async {
      await pushArrives();
      final sent = await tap(replyActionId, input: 'on my way');
      expect(sent, hasLength(1));
      expect(sent.single, {
        'token': _ticket.token,
        'conversation_id': _chat,
        'action': 'reply',
        'id': sent.single['id'],
        'body': 'on my way',
      });
      expect(
        sent.single['id'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('a failed reply is tried once more with the SAME id', () async {
      await pushArrives();
      final sent = await tap(
        replyActionId,
        input: 'on my way',
        statuses: [503, 200],
      );
      expect(sent, hasLength(2));
      expect(sent[1], sent[0], reason: 'the retry is the identical request');
    });

    test(
      'a lost answer (no response) is retried with the same id too',
      () async {
        await pushArrives();
        final sent = await tap(
          replyActionId,
          input: 'x',
          statuses: [null, 200],
        );
        expect(sent, hasLength(2));
        expect(sent[1]['id'], sent[0]['id']);
      },
    );

    test('only once more: two failures stop at two requests', () async {
      await pushArrives();
      final sent = await tap(
        replyActionId,
        input: 'x',
        statuses: [500, 429, 500],
      );
      expect(sent, hasLength(2));
    });

    test('a failed Mark as read is retried once', () async {
      await pushArrives();
      final sent = await tap(markReadActionId, statuses: [500, 200]);
      expect(sent, hasLength(2));
    });

    test('a refusal is not retried', () async {
      await pushArrives();
      final sent = await tap(replyActionId, input: 'x', statuses: [403]);
      expect(sent, hasLength(1));
    });

    test('no ticket for the chat: nothing is sent, nothing throws', () async {
      await pushArrives(ticket: null);
      expect(await tap(markReadActionId), isEmpty);
      expect(await tap(replyActionId, chat: _other, input: 'x'), isEmpty);
    });

    test('a blank reply is not sent', () async {
      await pushArrives();
      expect(await tap(replyActionId, input: '   '), isEmpty);
      expect(await tap(replyActionId), isEmpty);
    });
  });

  group('afterAction', () {
    NotificationAction action(String id, {String? input}) =>
        NotificationAction.fromResponse(
          actionId: id,
          conversationId: _chat,
          ticket: _ticket,
          input: input,
          newId: () => '0b6a1f8e-3c2d-4e5f-8a9b-665544332211',
        )!;

    test(
      'Mark as read done: the chat\'s notification leaves the shade',
      () async {
        await pushArrives();
        await pushArrives(chat: _other);
        expect(shade.childChats, containsAll([_chat, _other]));
        await LocalPushDisplay.afterAction(
          action(markReadActionId),
          NotificationActionResult.done,
        );
        expect(shade.childChats, isNot(contains(_chat)));
        expect(
          shade.childChats,
          contains(_other),
          reason: 'other chats untouched',
        );
      },
    );

    for (final result in [
      NotificationActionResult.rejected,
      NotificationActionResult.retry,
    ]) {
      test(
        'a reply that failed (${result.name}) says it was not sent',
        () async {
          await pushArrives();
          await LocalPushDisplay.afterAction(
            action(replyActionId, input: 'on my way'),
            result,
          );
          final notSent = notificationActionLabels('en').notSent;
          expect(Shade.text(shade.childFor(_chat)), contains(notSent));
        },
      );
    }

    test('a reply that went through does not say it failed', () async {
      await pushArrives();
      await LocalPushDisplay.afterAction(
        action(replyActionId, input: 'on my way'),
        NotificationActionResult.done,
      );
      final notSent = notificationActionLabels('en').notSent;
      for (final n in shade.children) {
        expect(Shade.text(n), isNot(contains(notSent)));
      }
    });
  });
}

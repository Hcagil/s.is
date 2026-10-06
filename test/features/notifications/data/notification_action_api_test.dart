// NotificationActionApi.send: one POST of the action to its ticket's url,
// mapped to done / rejected / retry. It runs in the notification button's
// background isolate, so it must never throw and never hang: the network is
// stood in for by a client that answers late, never, or with an error.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/features/notifications/data/notification_action_api.dart';
import 'package:sis/features/notifications/domain/notification_action.dart';

const _url = 'https://project.example/functions/v1/notification-action';
const _ticket = ActionTicket(token: 'v1.payload.sig', url: _url);
const _chat = '7d5c9e2a-1b3f-4c8d-9e0a-112233445566';
const _id = '0b6a1f8e-3c2d-4e5f-8a9b-665544332211';

NotificationAction _reply() => NotificationAction.fromResponse(
  actionId: replyActionId,
  conversationId: _chat,
  ticket: _ticket,
  input: 'on my way',
  newId: () => _id,
)!;

NotificationAction _markRead() => NotificationAction.fromResponse(
  actionId: markReadActionId,
  conversationId: _chat,
  ticket: _ticket,
  newId: () => 'unused',
)!;

void main() {
  test('POSTs the action as JSON to the ticket url, with no session', () async {
    final seen = <http.Request>[];
    final api = NotificationActionApi(
      client: MockClient((req) async {
        seen.add(req);
        return http.Response('{"ok":true}', 200);
      }),
    );
    expect(await api.send(_reply()), NotificationActionResult.done);
    expect(seen, hasLength(1));
    final req = seen.single;
    expect(req.method, 'POST');
    expect(req.url.toString(), _url);
    expect(req.headers['content-type'], startsWith('application/json'));
    expect(
      req.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(jsonDecode(req.body), {
      'token': 'v1.payload.sig',
      'conversation_id': _chat,
      'action': 'reply',
      'id': _id,
      'body': 'on my way',
    });
  });

  group('status mapping', () {
    final cases = <int, NotificationActionResult>{
      200: NotificationActionResult.done,
      201: NotificationActionResult.rejected,
      204: NotificationActionResult.rejected,
      400: NotificationActionResult.rejected,
      401: NotificationActionResult.rejected,
      403: NotificationActionResult.rejected,
      404: NotificationActionResult.rejected,
      405: NotificationActionResult.rejected,
      409: NotificationActionResult.rejected,
      428: NotificationActionResult.rejected,
      429: NotificationActionResult.retry,
      430: NotificationActionResult.rejected,
      500: NotificationActionResult.retry,
      502: NotificationActionResult.retry,
      503: NotificationActionResult.retry,
      504: NotificationActionResult.retry,
      599: NotificationActionResult.retry,
    };
    for (final MapEntry(key: status, value: want) in cases.entries) {
      test('$status is ${want.name}', () async {
        final api = NotificationActionApi(
          client: MockClient((_) async => http.Response('', status)),
        );
        expect(await api.send(_markRead()), want);
      });
    }
  });

  // Exceptions only: a Dart Error (StateError, TypeError) is a programming
  // bug, not a network condition, and is not part of the never-throws promise.
  group('no answer is retry, never a throw', () {
    final failures = <String, Object>{
      'ClientException': http.ClientException('connection reset'),
      'SocketException': const SocketException('no route'),
      'TimeoutException': TimeoutException('slow'),
      'HandshakeException': const HandshakeException('bad cert'),
      'a plain Exception': Exception('boom'),
    };
    for (final MapEntry(key: what, value: error) in failures.entries) {
      test(what, () async {
        final api = NotificationActionApi(
          client: MockClient((_) async => throw error),
        );
        expect(await api.send(_reply()), NotificationActionResult.retry);
      });
    }
  });

  testWidgets('no answer within 15 seconds is retry', (tester) async {
    final never = Completer<http.Response>();
    final api = NotificationActionApi(client: MockClient((_) => never.future));
    NotificationActionResult? result;
    unawaited(api.send(_markRead()).then((r) => result = r));
    await tester.pump(const Duration(seconds: 14));
    expect(result, isNull, reason: 'still waiting at 14 s');
    await tester.pump(const Duration(seconds: 1, milliseconds: 1));
    expect(result, NotificationActionResult.retry);
  });

  testWidgets('a slow answer inside 15 seconds still counts', (tester) async {
    final api = NotificationActionApi(
      client: MockClient(
        (_) => Future.delayed(
          const Duration(seconds: 13),
          () => http.Response('', 200),
        ),
      ),
    );
    NotificationActionResult? result;
    unawaited(api.send(_markRead()).then((r) => result = r));
    await tester.pump(const Duration(seconds: 13, milliseconds: 1));
    expect(result, NotificationActionResult.done);
  });
}

// A half-set row (exactly one of ciphertext and olm_type) must never show as
// plain text: the pinned bar and the chat-list preview show the locked
// placeholder instead. Plain and fully locked rows keep today's behaviour.
// The chat_list previews carry `olm_type` and `has_ciphertext` (the ciphertext
// itself is not sent); a preview without them (an older server) is plain.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_pin_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _me = '00000000-0000-4000-8000-000000000001';
const _peer = '00000000-0000-4000-8000-000000000002';
const _forged = 'forged plain text';

String _b64(Object o) =>
    base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');

/// A signed-in session built at run time (no token literal in the source).
String _session() => jsonEncode({
  'access_token': [
    _b64({'alg': 'none'}),
    _b64({'sub': _me, 'exp': 4102444800, 'aud': 'authenticated'}),
    'x',
  ].join('.'),
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': 4102444800,
  'refresh_token': 'r',
  'user': {
    'id': _me,
    'aud': 'authenticated',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-01-01T00:00:00Z',
  },
});

Map<String, Object?> _msg({String body = _forged, String? cipher, int? olm}) =>
    {
      'id': 'm1',
      'conversation_id': 'c1',
      'sender_id': _me,
      'body': body,
      'created_at': '2026-11-06T10:00:00Z',
      'ciphertext': cipher,
      'olm_type': olm,
    };

http.Response _json(http.BaseRequest req, int code, Object body) =>
    http.Response(
      jsonEncode(body),
      code,
      request: req,
      headers: {'content-type': 'application/json'},
    );

void main() {
  late Object Function(http.BaseRequest) serve;
  late SupabaseClient client;

  setUp(() async {
    client = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: MockClient((req) async => _json(req, 200, serve(req))),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.recoverSession(_session());
    expect(client.auth.currentUser?.id, _me);
  });

  group('pinned bar', () {
    Future<Message?> pinned(Map<String, Object?> row) async {
      serve = (_) => [row];
      final r = await SupabaseChatPinRepository(client)
          .pinnedMessage('c1', 'm1');
      return (r as Ok<Message?>).value;
    }

    test('ciphertext without olm type: placeholder', () async {
      expect((await pinned(_msg(cipher: 'Y3Q=')))!.body, lockedBodyPlaceholder);
    });
    test('olm type without ciphertext: placeholder', () async {
      expect((await pinned(_msg(olm: 1)))!.body, lockedBodyPlaceholder);
    });
    test('control: plain row keeps its text', () async {
      expect((await pinned(_msg()))!.body, _forged);
    });
    test('control: fully locked row stays locked', () async {
      final row = _msg(body: lockedBodyPlaceholder, cipher: 'Y3Q=', olm: 1);
      expect((await pinned(row))!.body, lockedBodyPlaceholder);
    });
  });

  group('chat-list preview', () {
    Future<String?> preview(Map<String, Object?> extra) async {
      serve = (_) => {
        'members': [
          {'conversation_id': 'c1', 'user_id': _me, 'color_slot': 0},
          {'conversation_id': 'c1', 'user_id': _peer, 'color_slot': 0},
        ],
        'conversations': [
          {'id': 'c1', 'title': null},
        ],
        'archives': [],
        'pins': [],
        'hides': [],
        'profiles': [
          {'user_id': _peer, 'display_name': 'Peer', 'avatar_path': null},
        ],
        'previews': [
          {
            'conversation_id': 'c1',
            'body': _forged,
            'created_at': '2026-11-06T10:00:00Z',
            'sender_id': _peer,
            ...extra,
          },
        ],
        'unread': [],
      };
      final r = await SupabaseChatRepository(client).conversations();
      return (r as Ok<List<Conversation>>).value.single.lastMessage;
    }

    test('has_ciphertext without olm type: placeholder', () async {
      expect(
        await preview({'has_ciphertext': true, 'olm_type': null}),
        lockedBodyPlaceholder,
      );
    });
    test('olm type without ciphertext: placeholder', () async {
      expect(
        await preview({'has_ciphertext': false, 'olm_type': 1}),
        lockedBodyPlaceholder,
      );
    });
    test('control: plain preview keeps its text', () async {
      expect(
        await preview({'has_ciphertext': false, 'olm_type': null}),
        _forged,
      );
    });
    test('control: fully locked preview keeps the stored text', () async {
      expect(
        await preview({
          'has_ciphertext': true,
          'olm_type': 1,
          'body': lockedBodyPlaceholder,
        }),
        lockedBodyPlaceholder,
      );
    });
    test('control: fields missing (older server) = plain', () async {
      expect(await preview({}), _forged);
    });
  });
}

// The pinned bar asks the server for the lock flag (`has_ciphertext`, a
// computed field) and `olm_type`, never the ciphertext itself (up to 64 KB).
// Half-set rows show the locked placeholder; plain and fully locked rows keep
// today's behaviour.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_pin_repository.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _me = '00000000-0000-4000-8000-000000000001';
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

Map<String, Object?> _msg({
  String body = _forged,
  required bool locked,
  int? olm,
}) => {
  'id': 'm1',
  'conversation_id': 'c1',
  'sender_id': _me,
  'body': body,
  'created_at': '2026-11-06T10:00:00Z',
  'has_ciphertext': locked,
  'olm_type': olm,
};

void main() {
  late Object Function(http.BaseRequest) serve;
  late List<http.BaseRequest> seen;
  late SupabaseClient client;

  setUp(() async {
    seen = [];
    client = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: MockClient((req) async {
        seen.add(req);
        return http.Response(
          jsonEncode(serve(req)),
          200,
          request: req,
          headers: {'content-type': 'application/json'},
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.recoverSession(_session());
    expect(client.auth.currentUser?.id, _me);
  });

  Future<Message?> pinned(Map<String, Object?> row) async {
    serve = (_) => [row];
    final r = await SupabaseChatPinRepository(client).pinnedMessage('c1', 'm1');
    return (r as Ok<Message?>).value;
  }

  test('select asks for the lock flag and never the ciphertext', () async {
    await pinned(_msg(locked: false));
    final select = seen.single.url.queryParameters['select']!;
    final cols = select.split(',').map((c) => c.trim()).toList();
    expect(cols, containsAll(['has_ciphertext', 'olm_type']));
    expect(cols, isNot(contains('ciphertext')));
  });
  test('flag without olm type: placeholder', () async {
    expect((await pinned(_msg(locked: true)))!.body, lockedBodyPlaceholder);
  });
  test('olm type without flag: placeholder', () async {
    expect(
      (await pinned(_msg(locked: false, olm: 1)))!.body,
      lockedBodyPlaceholder,
    );
  });
  test('control: plain row keeps its text', () async {
    expect((await pinned(_msg(locked: false)))!.body, _forged);
  });
  test('control: fully locked row stays locked', () async {
    final row = _msg(body: lockedBodyPlaceholder, locked: true, olm: 1);
    expect((await pinned(row))!.body, lockedBodyPlaceholder);
  });
}

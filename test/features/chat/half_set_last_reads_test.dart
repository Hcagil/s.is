// The last read paths that turn a server row into a message (shared media,
// shared links, search, and the encrypted repository's send / retry
// read-back / edit): a half-set row (exactly one of ciphertext and olm_type)
// must come back as the locked placeholder, never as plain text. Plain and
// fully locked rows keep today's behaviour.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/opener_fakes.dart';
import '../../support/security_code_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness;

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

Map<String, Object?> _row({String? cipher, int? olm, String body = _forged}) =>
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
  late Map<String, Object?> served;
  late bool duplicateFirst;
  late SupabaseClient client;
  late SupabaseChatRepository repo;
  late SupabaseEncryptedMessageRepository enc;

  setUp(() async {
    duplicateFirst = false;
    final h = await StoreHarness.create();
    final store = h.open(owner: _me, key: await h.newKey());
    addTearDown(store.close);
    final opener = StoreMessageOpener(
      me: () => _me,
      engine: () => ScriptEngine(),
      store: () => store,
      peerKey: FakePeerKeys().call,
      memory: () => FakeSecurityCodeStore(),
    );
    addTearDown(opener.dispose);
    client = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/rpc/search_messages')) {
          return _json(req, 200, [served]);
        }
        if (p.endsWith('/rpc/edit_message_encrypted')) {
          return _json(req, 200, served);
        }
        if (req.method == 'POST') {
          if (duplicateFirst) {
            return _json(req, 409, {'code': '23505', 'message': 'duplicate'});
          }
          return _json(req, 201, served);
        }
        final one = (req.headers['Accept'] ?? '').contains('vnd.pgrst.object');
        return _json(req, 200, one ? served : [served]);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.recoverSession(_session());
    expect(client.auth.currentUser?.id, _me);
    repo = SupabaseChatRepository(client, opener: opener);
    enc = SupabaseEncryptedMessageRepository(client);
  });

  final halfSet = <(String, String?, int?)>[
    ('ciphertext without olm type', 'Y3Q=', null),
    ('olm type without ciphertext', null, 1),
  ];

  final lists = <(String, Future<Result<List<Message>>> Function())>[
    ('sharedMedia', () => repo.sharedMedia('c1')),
    ('sharedLinks', () => repo.sharedLinks('c1')),
    ('search', () => repo.search('x')),
  ];
  for (final (path, call) in lists) {
    for (final (name, cipher, olm) in halfSet) {
      test('$path, $name: placeholder, never plain text', () async {
        served = _row(cipher: cipher, olm: olm);
        final r = await call();
        expect(r, isA<Ok<List<Message>>>());
        expect(
          (r as Ok<List<Message>>).value.single.body,
          lockedBodyPlaceholder,
        );
      });
    }
    test('control: $path with a plain row keeps its text', () async {
      served = _row();
      final r = await call();
      expect((r as Ok<List<Message>>).value.single.body, _forged);
    });
    test('control: $path with a locked row stays locked', () async {
      served = _row(cipher: 'Y3Q=', olm: 1, body: lockedBodyPlaceholder);
      final r = await call();
      expect((r as Ok<List<Message>>).value.single.body, lockedBodyPlaceholder);
    });
  }

  // The encrypted repository. Its insert/edit answers may carry the columns.
  final encPaths = <(String, Future<Result<Message>> Function())>[
    (
      'encrypted send',
      () => enc.send(
        id: 'm1',
        conversationId: 'c1',
        ciphertext: 'Y3Q=',
        olmType: 1,
      ),
    ),
    (
      'encrypted edit',
      () => enc.edit(id: 'm1', ciphertext: 'Y3Q=', olmType: 1),
    ),
  ];
  for (final (path, call) in encPaths) {
    for (final (name, cipher, olm) in halfSet) {
      test('$path, $name: placeholder, never plain text', () async {
        served = _row(cipher: cipher, olm: olm);
        final r = await call();
        expect(r, isA<Ok<Message>>());
        expect((r as Ok<Message>).value.body, lockedBodyPlaceholder);
      });
    }
  }

  test('encrypted send retry read-back, ciphertext without olm type: '
      'placeholder, never plain text', () async {
    duplicateFirst = true;
    served = _row(cipher: 'Y3Q=', olm: null);
    final r = await enc.send(
      id: 'm1',
      conversationId: 'c1',
      ciphertext: 'Y3Q=',
      olmType: 1,
    );
    expect(r, isA<Ok<Message>>());
    expect((r as Ok<Message>).value.body, lockedBodyPlaceholder);
  });

  test(
    'control: encrypted send retry with a fully locked row is ours',
    () async {
      duplicateFirst = true;
      served = _row(cipher: 'Y3Q=', olm: 1, body: lockedBodyPlaceholder);
      final r = await enc.send(
        id: 'm1',
        conversationId: 'c1',
        ciphertext: 'Y3Q=',
        olmType: 1,
      );
      expect((r as Ok<Message>).value.body, lockedBodyPlaceholder);
    },
  );
}

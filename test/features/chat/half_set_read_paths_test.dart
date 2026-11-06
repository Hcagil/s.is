// A forged half-set row (ciphertext without olm type, or the reverse) that the
// server hands back on a write's read-back must reach the screen as the
// locked placeholder, exactly as on the _open read paths; never as plain
// text. Paths: send (insert read-back), send (retry read-back after a
// duplicate-id answer), sendImage (insert read-back), editMessage (rpc
// answer). The real repository runs over a stand-in PostgREST/storage.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/opener_fakes.dart';
import '../../support/security_code_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

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
  late SupabaseChatRepository repo;
  late StoreMessageOpener opener;

  setUp(() async {
    duplicateFirst = false;
    final h = await StoreHarness.create();
    final store = h.open(owner: _me, key: await h.newKey());
    addTearDown(store.close);
    opener = StoreMessageOpener(
      me: () => _me,
      engine: () => ScriptEngine(),
      store: () => store,
      peerKey: FakePeerKeys().call,
      memory: () => FakeSecurityCodeStore(),
    );
    addTearDown(opener.dispose);
    final client = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: MockClient((req) async {
        final p = req.url.path;
        if (p.startsWith('/storage/v1/')) return _json(req, 200, {'Key': 'k'});
        if (p.endsWith('/rpc/edit_message')) return _json(req, 200, served);
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
  });

  final halfSet = <(String, String?, int?)>[
    ('ciphertext without olm type', 'Y3Q=', null),
    ('olm type without ciphertext', null, 1),
  ];

  Future<Result<Message>> viaSend() =>
      repo.send(id: 'm1', conversationId: 'c1', body: _forged);
  Future<Result<Message>> viaRetry() {
    duplicateFirst = true;
    return viaSend();
  }

  Future<Result<Message>> viaImage() => repo.sendImage(
    conversationId: 'c1',
    image: PickedImage(
      bytes: Uint8List.fromList([1, 2, 3]),
      contentType: 'image/jpeg',
      extension: 'jpg',
    ),
    body: _forged,
  );
  Future<Result<Message>> viaEdit() => repo.editMessage(
    Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: _me,
      body: 'old',
      createdAt: at(1),
    ),
    _forged,
  );

  final paths = <(String, Future<Result<Message>> Function())>[
    ('send', viaSend),
    ('send retry read-back', viaRetry),
    ('sendImage', viaImage),
    ('editMessage', viaEdit),
  ];

  for (final (path, call) in paths) {
    for (final (name, cipher, olm) in halfSet) {
      test('$path, $name: placeholder, never plain text', () async {
        served = _row(cipher: cipher, olm: olm);
        final r = await call();
        expect(r, isA<Ok<Message>>());
        expect((r as Ok<Message>).value.body, lockedBodyPlaceholder);
      });
    }
  }

  test('control: send with a plain row keeps its text', () async {
    served = _row();
    final r = await viaSend();
    expect((r as Ok<Message>).value.body, _forged);
  });

  test('control: edit with a plain row keeps its text', () async {
    served = _row();
    final r = await viaEdit();
    expect((r as Ok<Message>).value.body, _forged);
  });

  test(
    'harness: the same opener turns a half-set row into the placeholder',
    () async {
      final m = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: _me,
        body: _forged,
        createdAt: at(1),
        olmType: 1,
      );
      expect((await opener.open([m])).single.body, lockedBodyPlaceholder);
    },
  );
}

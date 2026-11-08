// The small photo copy `<path>.s` at the storage seam, written from the
// contract: SupabaseChatRepository over a real SupabaseClient whose HTTP is
// a MockClient (the storage API's request shapes are the boundary here; the
// real bucket and RLS are covered by the stack tests).
// - attachmentThumbBytes: cache first under `<path>.s`; else downloads
//   `<path>.s` only; a StorageException is Ok(null) and that path is not asked
//   again this run; a network error is Err.
// - sendImage uploads `<path>.s` (JPEG, long side <= 560) before the row
//   insert; a refused `.s` upload still sends the photo.
// - forward copies `<source>.s` to `<target>.s`.
// - deleteDirectChat removes path, path.t and path.s; a refused removal is
//   still Ok.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:imcodec/imcodec.dart' as img;
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_delete_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _me = '00000000-0000-4000-8000-000000000001';

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

http.Response _json(http.BaseRequest req, int code, Object? body) =>
    http.Response(
      jsonEncode(body),
      code,
      request: req,
      headers: {'content-type': 'application/json'},
    );

http.Response _storageError(http.BaseRequest req, int code) => _json(
  req,
  code,
  {'statusCode': '$code', 'error': 'not_found', 'message': 'Object not found'},
);

Uint8List _noisePng(int w, int h) {
  final rnd = Random(5);
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i++) {
    px[i] = (i % 4 == 3) ? 255 : rnd.nextInt(256);
  }
  return img.encodePng(
    img.Image.fromBytes(
      width: w,
      height: h,
      bytes: px.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    ),
  );
}

/// The file bytes of a storage upload: the multipart part with a filename,
/// or the raw body when the upload is not multipart.
Uint8List _filePart(http.Request req) {
  final type = req.headers['content-type'] ?? '';
  final m = RegExp('boundary=(.+)').firstMatch(type);
  if (m == null) return req.bodyBytes;
  final body = req.bodyBytes;
  final sep = latin1.encode('--${m.group(1)}');
  final starts = <int>[];
  for (var i = 0; i + sep.length <= body.length; i++) {
    var hit = true;
    for (var j = 0; j < sep.length && hit; j++) {
      hit = body[i + j] == sep[j];
    }
    if (hit) starts.add(i);
  }
  for (var k = 0; k + 1 < starts.length; k++) {
    final part = body.sublist(starts[k] + sep.length, starts[k + 1] - 2);
    final text = latin1.decode(part);
    final split = text.indexOf('\r\n\r\n');
    if (split > 0 && text.substring(0, split).contains('filename=')) {
      return Uint8List.fromList(part.sublist(split + 4));
    }
  }
  throw StateError('no file part in upload');
}

class _MemoryCache implements AttachmentCache {
  final files = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String path) async => files[path];
  @override
  Future<void> write(String path, Uint8List bytes) async => files[path] = bytes;
  @override
  Future<void> remove(String path) async => files.remove(path);
  @override
  Future<void> clear() async => files.clear();
}

/// What the storage and database saw, in order.
class _Wire {
  final log = <String>[];
  final uploads = <String, Uint8List>{};
  final copies = <(String, String)>[];
  final removed = <String>[];
  final objects = <String, Uint8List>{};
  final refuse = <String>{};
  bool networkDown = false;
  int removeStatus = 200;

  /// When set, a GET answers with this (status, error) instead of the data.
  (int, String)? getFail;

  late final SupabaseClient client = SupabaseClient(
    'http://supabase.test',
    'publishable-key',
    httpClient: MockClient((req) async {
      final p = Uri.decodeFull(req.url.path);
      if (networkDown) throw http.ClientException('no network', req.url);
      const obj = '/storage/v1/object/';
      if (p == '${obj}copy') {
        final b = jsonDecode(req.body) as Map<String, Object?>;
        final to = b['destinationKey']! as String;
        copies.add((b['sourceKey']! as String, to));
        log.add('copy $to');
        return _json(req, 200, {'Key': 'attachments/$to'});
      }
      if (req.method == 'DELETE' && p == '${obj}attachments') {
        final b = jsonDecode(req.body) as Map<String, Object?>;
        removed.addAll((b['prefixes']! as List).cast<String>());
        if (removeStatus != 200) return _storageError(req, removeStatus);
        return _json(req, 200, <Object>[]);
      }
      if (p.startsWith('${obj}attachments/')) {
        final key = p.substring('${obj}attachments/'.length);
        log.add('${req.method} $key');
        if (req.method == 'GET') {
          final f = getFail;
          if (f != null) {
            return _json(req, f.$1, {
              'statusCode': '${f.$1}',
              'error': f.$2,
              'message': 'storage said ${f.$2}',
            });
          }
          final bytes = objects[key];
          if (bytes == null) return _storageError(req, 404);
          return http.Response.bytes(bytes, 200, request: req);
        }
        if (refuse.contains(key.split('.').last)) {
          return _storageError(req, 400);
        }
        uploads[key] = _filePart(req);
        return _json(req, 200, {'Key': 'attachments/$key'});
      }
      if (p.startsWith('/storage/v1/')) return _json(req, 200, {'Key': 'k'});
      if (p.endsWith('/rpc/delete_direct_chat')) {
        log.add('rpc delete_direct_chat');
        return _json(req, 200, ['c1/a.png']);
      }
      if (p.contains('/rpc/')) return _json(req, 200, null);
      if (req.method == 'POST' && p.endsWith('/messages')) {
        log.add('insert messages');
        final b = jsonDecode(req.body);
        final row = (b is List ? b.first : b) as Map<String, Object?>;
        return _json(req, 201, {
          'id': row['id'] ?? 'm1',
          'conversation_id': row['conversation_id'] ?? 'c1',
          'sender_id': _me,
          'body': row['body'] ?? '',
          'created_at': '2026-11-06T10:00:00Z',
          'attachment_path': row['attachment_path'],
        });
      }
      if (req.method == 'POST') return _json(req, 201, <Object>[]);
      final one = (req.headers['Accept'] ?? '').contains('vnd.pgrst.object');
      return _json(req, 200, one ? <String, Object?>{} : <Object>[]);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  Future<void> signIn() => client.auth.recoverSession(_session());
}

void main() {
  late _Wire wire;
  late _MemoryCache cache;
  late SupabaseChatRepository repo;
  final small = Uint8List.fromList([7, 7, 7]);
  final full = Uint8List.fromList([1, 1, 1, 1]);

  setUp(() async {
    wire = _Wire();
    await wire.signIn();
    cache = _MemoryCache();
    repo = SupabaseChatRepository(wire.client, cache: cache);
  });

  group('attachmentThumbBytes', () {
    test('downloads only <path>.s and keeps it under that name', () async {
      wire.objects['c1/a.png.s'] = small;
      wire.objects['c1/a.png'] = full;

      final r = await repo.attachmentThumbBytes('c1/a.png');

      expect((r as Ok<Uint8List?>).value, small);
      expect(wire.log, ['GET c1/a.png.s']);
      expect(cache.files['c1/a.png.s'], small);
      expect(
        cache.files.containsKey('c1/a.png'),
        isFalse,
        reason: 'the small copy must never stand in for the full photo',
      );
    });

    test('a cached small copy is used with no request', () async {
      cache.files['c1/a.png.s'] = small;

      final r = await repo.attachmentThumbBytes('c1/a.png');

      expect((r as Ok<Uint8List?>).value, small);
      expect(wire.log, isEmpty);
    });

    test('a cached full photo is not served as the small copy', () async {
      cache.files['c1/a.png'] = full;
      wire.objects['c1/a.png.s'] = small;

      final r = await repo.attachmentThumbBytes('c1/a.png');

      expect((r as Ok<Uint8List?>).value, small);
    });

    test('no small copy (404) is Ok(null), and is not asked again', () async {
      final first = await repo.attachmentThumbBytes('c1/old.png');
      final second = await repo.attachmentThumbBytes('c1/old.png');

      expect((first as Ok<Uint8List?>).value, isNull);
      expect((second as Ok<Uint8List?>).value, isNull);
      expect(wire.log, ['GET c1/old.png.s']);
    });

    for (final (status, error) in [(500, 'internal'), (400, 'bad_request')]) {
      test('a $status "$error" is an Err and is asked again later', () async {
        wire
          ..getFail = (status, error)
          ..objects['c1/a.png.s'] = small;
        final r = await repo.attachmentThumbBytes('c1/a.png');
        expect(r, isA<Err<Uint8List?>>());

        wire.getFail = null;
        final again = await repo.attachmentThumbBytes('c1/a.png');
        expect((again as Ok<Uint8List?>).value, small);
        expect(wire.log, ['GET c1/a.png.s', 'GET c1/a.png.s']);
      });
    }

    test(
      'a 400 not_found (local stack) is Ok(null), not asked again',
      () async {
        wire.getFail = (400, 'not_found');
        final first = await repo.attachmentThumbBytes('c1/old.png');
        wire.getFail = (500, 'internal');
        final second = await repo.attachmentThumbBytes('c1/old.png');

        expect((first as Ok<Uint8List?>).value, isNull);
        expect((second as Ok<Uint8List?>).value, isNull);
        expect(wire.log, ['GET c1/old.png.s']);
      },
    );

    test('a miss for one photo does not hide another photo\'s copy', () async {
      wire.objects['c1/b.png.s'] = small;
      await repo.attachmentThumbBytes('c1/old.png');

      final r = await repo.attachmentThumbBytes('c1/b.png');

      expect((r as Ok<Uint8List?>).value, small);
    });

    test('a network error is an Err and is asked again later', () async {
      wire.networkDown = true;
      final r = await repo.attachmentThumbBytes('c1/a.png');
      expect(r, isA<Err<Uint8List?>>());

      wire
        ..networkDown = false
        ..objects['c1/a.png.s'] = small;
      final again = await repo.attachmentThumbBytes('c1/a.png');
      expect((again as Ok<Uint8List?>).value, small);
    });
  });

  group('sendImage', () {
    PickedImage picked() => PickedImage(
      bytes: _noisePng(1200, 900),
      contentType: 'image/png',
      extension: 'png',
    );

    test('uploads <path>.s, a JPEG with long side <= 560, before the '
        'message row', () async {
      final r = await repo.sendImage(conversationId: 'c1', image: picked());

      expect(r, isA<Ok<Message>>());
      final fullKey = wire.uploads.keys.firstWhere((k) => k.endsWith('.png'));
      final s = wire.uploads['$fullKey.s'];
      expect(s, isNotNull, reason: 'uploaded: ${wire.uploads.keys}');
      expect(s!.sublist(0, 3), [0xff, 0xd8, 0xff], reason: 'JPEG');
      expect(s.length, lessThanOrEqualTo(153600));
      final decoded = img.decodeJpg(s);
      expect(decoded.width, 560);
      expect(decoded.height, 420);
      expect(
        wire.log.indexOf('POST $fullKey.s'),
        lessThan(wire.log.indexOf('insert messages')),
        reason: 'a receiver may open the bubble as soon as the row exists',
      );
    });

    test('a refused small copy upload still sends the photo', () async {
      wire.refuse.add('s');

      final r = await repo.sendImage(conversationId: 'c1', image: picked());

      expect(r, isA<Ok<Message>>());
      expect(wire.log, contains('insert messages'));
      expect(wire.uploads.keys.where((k) => k.endsWith('.png')), hasLength(1));
    });
  });

  test('forward copies the small copy next to the forwarded photo', () async {
    final photo = Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'someone',
      body: '',
      createdAt: DateTime.utc(2026, 11, 6),
      attachmentPath: 'c1/a.png',
    );

    final r = await repo.forward(photo, ['c2']);

    expect(r, isA<Ok<void>>(), reason: '$r');
    final main = wire.copies.firstWhere((c) => c.$1 == 'c1/a.png');
    expect(main.$2, startsWith('c2/'));
    expect(wire.copies, contains(('c1/a.png.s', '${main.$2}.s')));
  });

  group('deleteDirectChat', () {
    test('removes each photo with its .t and .s copies', () async {
      final r = await SupabaseChatDeleteRepository(wire.client)
          .deleteDirectChat('c1');

      expect(r, isA<Ok<void>>());
      expect(
        wire.removed,
        containsAll(['c1/a.png', 'c1/a.png.t', 'c1/a.png.s']),
      );
    });

    test('a refused removal is still Ok', () async {
      wire.removeStatus = 403;

      final r = await SupabaseChatDeleteRepository(wire.client)
          .deleteDirectChat('c1');

      expect(r, isA<Ok<void>>());
      expect(wire.removed, contains('c1/a.png.s'));
    });
  });
}

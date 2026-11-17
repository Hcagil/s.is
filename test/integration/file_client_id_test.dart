@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/data/supabase_chat_file_repository.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/domain/voice.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _pw = 'int-pw';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _pw);
  } on AuthException {
    await client.auth.signUp(email: email, password: _pw);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

PickedFile _file(
  Directory tmp,
  String id, {
  String name = 'note.txt',
  String mime = 'text/plain',
}) {
  final dir = Directory('${tmp.path}/$id')..createSync(recursive: true);
  final f = File('${dir.path}/$name')
    ..writeAsBytesSync(List<int>.filled(2000, 7));
  return PickedFile(id: id, path: f.path, name: name, mime: mime, size: 2000);
}

Future<void> expectDenied(Result<Message> r, String why) async {
  expect(r, isA<Err<Message>>(), reason: why);
  final f = (r as Err<Message>).failure;
  expect(f, isA<DeniedFailure>(), reason: 'got ${f.runtimeType}: $f');
  expect(
    f is NetworkFailure && f.retryable,
    isFalse,
    reason: 'a taken id is not "no connection": retrying cannot help',
  );
}

Future<List<Map<String, dynamic>>> rows(SupabaseClient as, String id) async =>
    await as
        .from('messages')
        .select(
          'id, conversation_id, sender_id, body, created_at, attachment_path',
        )
        .eq('id', id);

Message _ok(Result<Message> r, String what) {
  expect(r, isA<Ok<Message>>(), reason: '$what: $r');
  return (r as Ok<Message>).value;
}

PickedFile _video(Directory tmp, String id) {
  final dir = Directory('${tmp.path}/$id')..createSync(recursive: true);
  final f = File('${dir.path}/clip.mp4')
    ..writeAsBytesSync(List<int>.filled(2000, 7));
  final t = File('${dir.path}/thumb.jpg')
    ..writeAsBytesSync(List<int>.filled(500, 9));
  return PickedFile(
    id: id,
    path: f.path,
    name: 'clip.mp4',
    mime: videoMime,
    size: 2000,
    durationMs: 4000,
    thumbPath: t.path,
  );
}

PickedFile _voice(Directory tmp, String id) {
  final dir = Directory('${tmp.path}/$id')..createSync(recursive: true);
  final f = File('${dir.path}/voice.m4a')
    ..writeAsBytesSync(List<int>.filled(2000, 7));
  return PickedFile(
    id: id,
    path: f.path,
    name: 'voice.m4a',
    mime: voiceMime,
    size: 2000,
    durationMs: 4200,
    waveform: '0123456789abcdef0123456789abcdef01234567',
    transcript: 'see you at nine',
  );
}

void main() {
  HttpOverrides.global = null;

  late SupabaseClient umutClient, zaneClient, vedatClient;
  late SupabaseChatRepository umut, zane;
  late SupabaseChatFileRepository umutFiles, zaneFiles;
  late String umutZane, umutVedat, zaneVedat;

  final tmp = Directory.systemTemp.createTempSync('file-client-id');

  Future<String> direct(SupabaseChatRepository a, SupabaseClient b) async {
    final r = await a.startGroupConversation(
      title: 'file ids ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [b.auth.currentUser!.id],
    );
    return (r as Ok<String>).value;
  }

  setUpAll(() async {
    umutClient = await _signedIn('umut@mail.test');
    zaneClient = await _signedIn('zane@mail.test');
    vedatClient = await _signedIn('vedat@mail.test');
    umut = SupabaseChatRepository(umutClient);
    zane = SupabaseChatRepository(zaneClient);
    umutFiles = SupabaseChatFileRepository(umutClient);
    zaneFiles = SupabaseChatFileRepository(zaneClient);
    await findByTag(umutClient, [zaneClient, vedatClient]);
    await findByTag(zaneClient, [vedatClient]);
    await findByTag(vedatClient, []);
    umutZane = await direct(umut, zaneClient);
    umutVedat = await direct(umut, vedatClient);
    zaneVedat = await direct(zane, vedatClient);
  });

  tearDownAll(() async {
    await umutClient.dispose();
    await zaneClient.dispose();
    await vedatClient.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('a file is stored under the id the phone made', () async {
    final id = randomMessageId();
    final r = _ok(await umutFiles.send(umutZane, _file(tmp, id)), 'send');
    expect(r.id, id);
    final found = await rows(zaneClient, id);
    expect(found, hasLength(1));
    expect(found.single['sender_id'], umutClient.auth.currentUser!.id);
  });

  test('the same file sent twice is one row', () async {
    final id = randomMessageId();
    _ok(await umutFiles.send(umutZane, _file(tmp, id)), 'first');
    final again = _ok(await umutFiles.send(umutZane, _file(tmp, id)), 'retry');
    expect(again.id, id);
    expect(again.conversationId, umutZane);
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('a file id that belongs to someone else is refused', () async {
    final id = randomMessageId();
    _ok(await zaneFiles.send(umutZane, _file(tmp, id)), 'zane first');
    final before = await rows(zaneClient, id);
    final r = await umutFiles.send(umutZane, _file(tmp, id));
    await expectDenied(r, 'retry of someone else');
    expect(await rows(zaneClient, id), before);
  });

  test('own file id from chat A into chat B is refused', () async {
    final id = randomMessageId();
    _ok(await umutFiles.send(umutZane, _file(tmp, id)), 'first');
    final r = await umutFiles.send(umutVedat, _file(tmp, id));
    await expectDenied(r, 'own id into another chat');
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('a file id from an unreadable chat is refused', () async {
    final id = randomMessageId();
    _ok(await zaneFiles.send(zaneVedat, _file(tmp, id)), 'zane first');
    final before = await rows(zaneClient, id);
    final r = await umutFiles.send(umutZane, _file(tmp, id));
    await expectDenied(r, 'unreadable chat id');
    expect(await rows(zaneClient, id), before);
  });

  test('a retry with a different reply target is refused', () async {
    final quotedA = _ok(
      await zane.send(
        id: randomMessageId(),
        conversationId: umutZane,
        body: _stamp('quoted A'),
      ),
      'quoted A',
    );
    final quotedB = _ok(
      await zane.send(
        id: randomMessageId(),
        conversationId: umutZane,
        body: _stamp('quoted B'),
      ),
      'quoted B',
    );
    final id = randomMessageId();
    _ok(
      await umutFiles.send(umutZane, _file(tmp, id), replyTo: quotedA.id),
      'first',
    );
    final r = await umutFiles.send(
      umutZane,
      _file(tmp, id),
      replyTo: quotedB.id,
    );
    await expectDenied(r, 'different reply target');
    final row = await umutClient
        .from('messages')
        .select('reply_to')
        .eq('id', id)
        .single();
    expect(row['reply_to'], quotedA.id);
    expect(await rows(umutClient, id), hasLength(1));
  });

  test(
    'a retry with no reply where the stored row has one is refused',
    () async {
      final quoted = _ok(
        await zane.send(
          id: randomMessageId(),
          conversationId: umutZane,
          body: _stamp('quoted'),
        ),
        'quoted',
      );
      final id = randomMessageId();
      _ok(
        await umutFiles.send(umutZane, _file(tmp, id), replyTo: quoted.id),
        'first',
      );
      final r = await umutFiles.send(umutZane, _file(tmp, id));
      await expectDenied(r, 'no reply but stored has one');
      final row = await umutClient
          .from('messages')
          .select('reply_to')
          .eq('id', id)
          .single();
      expect(row['reply_to'], quoted.id);
      expect(await rows(umutClient, id), hasLength(1));
    },
  );

  test(
    'a retry with a reply where the stored row has none is refused',
    () async {
      final quoted = _ok(
        await zane.send(
          id: randomMessageId(),
          conversationId: umutZane,
          body: _stamp('quoted'),
        ),
        'quoted',
      );
      final id = randomMessageId();
      _ok(await umutFiles.send(umutZane, _file(tmp, id)), 'first');
      final r = await umutFiles.send(
        umutZane,
        _file(tmp, id),
        replyTo: quoted.id,
      );
      await expectDenied(r, 'reply but stored has none');
      final row = await umutClient
          .from('messages')
          .select('reply_to')
          .eq('id', id)
          .single();
      expect(row['reply_to'], isNull);
      expect(await rows(umutClient, id), hasLength(1));
    },
  );

  test('a retry with the same reply target keeps the stored row', () async {
    final quoted = _ok(
      await zane.send(
        id: randomMessageId(),
        conversationId: umutZane,
        body: _stamp('quoted'),
      ),
      'quoted',
    );
    final id = randomMessageId();
    _ok(
      await umutFiles.send(umutZane, _file(tmp, id), replyTo: quoted.id),
      'first',
    );
    final second = _ok(
      await umutFiles.send(umutZane, _file(tmp, id), replyTo: quoted.id),
      'second',
    );
    expect(second.replyTo, quoted.id);
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('a video id that belongs to someone else is refused', () async {
    final id = randomMessageId();
    _ok(await zaneFiles.send(umutZane, _video(tmp, id)), 'zane first');
    final before = await rows(zaneClient, id);
    final r = await umutFiles.send(umutZane, _video(tmp, id));
    await expectDenied(r, 'video id of someone else');
    expect(await rows(zaneClient, id), before);
  });

  test('a voice id that belongs to someone else is refused', () async {
    final id = randomMessageId();
    _ok(await zaneFiles.send(umutZane, _voice(tmp, id)), 'zane first');
    final before = await rows(zaneClient, id);
    final r = await umutFiles.send(umutZane, _voice(tmp, id));
    await expectDenied(r, 'voice id of someone else');
    expect(await rows(zaneClient, id), before);
  });

  test(
    'a file id of someone else is refused even with another file name',
    () async {
      final id = randomMessageId();
      _ok(await zaneFiles.send(umutZane, _file(tmp, id)), 'zane first');
      final before = await rows(zaneClient, id);
      final r = await umutFiles.send(
        umutZane,
        _file(tmp, id, name: 'other-name.pdf', mime: 'application/pdf'),
      );
      await expectDenied(r, 'retry of someone else');
      expect(await rows(zaneClient, id), before);
    },
  );

  test(
    'a video id of someone else is refused even with another file name',
    () async {
      final id = randomMessageId();
      _ok(await zaneFiles.send(umutZane, _video(tmp, id)), 'zane first');
      final before = await rows(zaneClient, id);
      final dir = Directory('${tmp.path}/${id}b')..createSync(recursive: true);
      final f = File('${dir.path}/other.mp4')
        ..writeAsBytesSync(List<int>.filled(1500, 3));
      final t = File('${dir.path}/other.jpg')
        ..writeAsBytesSync(List<int>.filled(300, 9));
      final picked = PickedFile(
        id: id,
        path: f.path,
        name: 'other.mp4',
        mime: videoMime,
        size: 1500,
        durationMs: 9000,
        thumbPath: t.path,
      );
      final r = await umutFiles.send(umutZane, picked);
      await expectDenied(r, 'video id of someone else');
      expect(await rows(zaneClient, id), before);
    },
  );

  test(
    'a voice id of someone else is refused even with another file name',
    () async {
      final id = randomMessageId();
      _ok(await zaneFiles.send(umutZane, _voice(tmp, id)), 'zane first');
      final before = await rows(zaneClient, id);
      final dir = Directory('${tmp.path}/${id}b')..createSync(recursive: true);
      final f = File('${dir.path}/other.m4a')
        ..writeAsBytesSync(List<int>.filled(1500, 3));
      final picked = PickedFile(
        id: id,
        path: f.path,
        name: 'other.m4a',
        mime: voiceMime,
        size: 1500,
        durationMs: 3000,
        waveform: 'abcdefghijklmnopqrstuvwxyz0123456789abcd',
        transcript: 'other words',
      );
      final r = await umutFiles.send(umutZane, picked);
      await expectDenied(r, 'voice id of someone else');
      expect(await rows(zaneClient, id), before);
    },
  );
}

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/data/supabase_chat_file_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

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

Future<Map<String, dynamic>> fullRow(SupabaseClient c, String id) async =>
    await c
        .from('messages')
        .select(
          'id, conversation_id, sender_id, body, attachment_path, reply_to',
        )
        .eq('id', id)
        .single();

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage _img(String id) => PickedImage(
  bytes: _png,
  contentType: 'image/png',
  extension: 'png',
  id: id,
);

void main() {
  HttpOverrides.global = null;

  late SupabaseClient annClient, bobClient;
  late SupabaseChatRepository annRepo, bobRepo;
  late SupabaseChatFileRepository annFiles;
  late SupabaseClient service;

  final tmp = Directory.systemTemp.createTempSync('file-retry-edge');

  Future<String> freshChat() async {
    final r = await annRepo.startGroupConversation(
      title: 'fre ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [bobClient.auth.currentUser!.id],
    );
    return (r as Ok<String>).value;
  }

  setUpAll(() async {
    annClient = await _signedIn('fre-ann@sis.test');
    bobClient = await _signedIn('fre-bob@sis.test');
    annRepo = SupabaseChatRepository(annClient);
    bobRepo = SupabaseChatRepository(bobClient);
    annFiles = SupabaseChatFileRepository(annClient);
    service = SupabaseClient(_url, serviceKey());
    await findByTag(annClient, [bobClient]);
    await findByTag(bobClient, [annClient]);
  });

  tearDownAll(() async {
    await annClient.dispose();
    await bobClient.dispose();
    await service.dispose();
    tmp.deleteSync(recursive: true);
  });

  group('file retry edge cases', () {
    test('own matching file retry is still accepted', () async {
      final conv = await freshChat();
      final id = randomMessageId();
      final quoted = _ok(
        await bobRepo.send(
          id: randomMessageId(),
          conversationId: conv,
          body: _stamp('quoted'),
        ),
        'quoted',
      );
      _ok(
        await annFiles.send(conv, _file(tmp, id), replyTo: quoted.id),
        'first',
      );
      final second = _ok(
        await annFiles.send(conv, _file(tmp, id), replyTo: quoted.id),
        'second',
      );
      expect(second.id, id);
      expect(await rows(annClient, id), hasLength(1));
    });

    test(
      'a file send whose id is already my text message is refused',
      () async {
        final conv = await freshChat();
        final quoted = _ok(
          await bobRepo.send(
            id: randomMessageId(),
            conversationId: conv,
            body: _stamp('quoted'),
          ),
          'quoted',
        );
        final id = randomMessageId();
        _ok(
          await annRepo.send(
            id: id,
            conversationId: conv,
            body: _stamp('mine'),
            replyTo: quoted.id,
          ),
          'text',
        );
        final before = await fullRow(annClient, id);
        final rFile = await annFiles.send(
          conv,
          _file(tmp, id),
          replyTo: quoted.id,
        );
        await expectDenied(rFile, 'file onto my own text id');
        expect(await fullRow(annClient, id), before);
        expect(before['attachment_path'], isNull);
      },
    );

    test('a file send whose id is already my photo is refused', () async {
      final conv = await freshChat();
      final quoted = _ok(
        await bobRepo.send(
          id: randomMessageId(),
          conversationId: conv,
          body: _stamp('quoted'),
        ),
        'quoted',
      );
      final id = randomMessageId();
      _ok(
        await annRepo.sendImage(
          conversationId: conv,
          image: _img(id),
          body: _stamp('photo'),
          replyTo: quoted.id,
        ),
        'photo',
      );
      final before = await fullRow(annClient, id);
      final rFile = await annFiles.send(
        conv,
        _file(tmp, id),
        replyTo: quoted.id,
      );
      await expectDenied(rFile, 'file onto my own photo id');
      expect(await fullRow(annClient, id), before);
      expect(before['attachment_path'], isNotNull);
    });

    test('my own file lands at conv/id in storage', () async {
      final conv = await freshChat();
      final id = randomMessageId();
      final r = _ok(await annFiles.send(conv, _file(tmp, id)), 'send');
      expect(r.id, id);
      final listed = await service.storage
          .from('attachments')
          .list(path: conv, searchOptions: const SearchOptions(limit: 1000));
      expect(listed.map((f) => f.name).toList(), contains(id));
    });

    test('my own earlier upload at my path is still accepted', () async {
      final conv = await freshChat();
      final id = randomMessageId();
      await annClient.storage
          .from('attachments')
          .uploadBinary(
            '$conv/$id',
            Uint8List.fromList(List<int>.filled(2000, 7)),
          );
      final r = _ok(await annFiles.send(conv, _file(tmp, id)), 'send');
      expect(r.id, id);
      expect(await rows(annClient, id), hasLength(1));
    });

    test('a file send never points to another member\'s object', () async {
      final conv = await freshChat();
      final id = randomMessageId();
      final other = Uint8List.fromList(utf8.encode('bob private bytes'));
      await bobClient.storage
          .from('attachments')
          .uploadBinary('$conv/$id', other);
      final r = await annFiles.send(conv, _file(tmp, id));
      final bobObj = await service.storage
          .from('attachments')
          .download('$conv/$id');
      expect(bobObj, other);
      if (r is Ok<Message>) {
        final row = await fullRow(annClient, id);
        expect(
          row['attachment_path'],
          isNot('$conv/$id'),
          reason: 'the message points to another member\'s upload',
        );
        final stored = await service.storage
            .from('attachments')
            .download(row['attachment_path'] as String);
        expect(stored, isNot(other));
      } else {
        expect(await rows(annClient, id), isEmpty);
      }
    });
  });
}

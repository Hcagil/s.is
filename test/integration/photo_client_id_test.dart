@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/request_log_host.dart';
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

Message _ok(Result<Message> r, String what) {
  expect(r, isA<Ok<Message>>(), reason: '$what: $r');
  return (r as Ok<Message>).value;
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage _img(String id) => PickedImage(
  bytes: _png,
  contentType: 'image/png',
  extension: 'png',
  id: id,
);

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

Future<Set<String>> objectNames(SupabaseClient service, String dir) async {
  final listed = await service.storage
      .from('attachments')
      .list(path: dir, searchOptions: const SearchOptions(limit: 1000));
  return {for (final f in listed) f.name};
}

void main() {
  HttpOverrides.global = null;

  late SupabaseClient umutClient, zaneClient, vedatClient;
  late SupabaseChatRepository umut, zane;
  late String umutZane, umutVedat, zaneVedat;

  Future<String> direct(SupabaseChatRepository a, SupabaseClient b) async {
    final r = await a.startDirectConversation(b.auth.currentUser!.id);
    return (r as Ok<String>).value;
  }

  setUpAll(() async {
    umutClient = await _signedIn('umut@mail.test');
    zaneClient = await _signedIn('zane@mail.test');
    vedatClient = await _signedIn('vedat@mail.test');
    umut = SupabaseChatRepository(umutClient);
    zane = SupabaseChatRepository(zaneClient);
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
  });

  Future<List<Map<String, dynamic>>> rows(SupabaseClient as, String id) async =>
      await as
          .from('messages')
          .select(
            'id, conversation_id, sender_id, body, created_at, attachment_path',
          )
          .eq('id', id);

  test('a photo is stored under the id the phone made for it', () async {
    final id = randomMessageId();
    final body = _stamp('fresh');
    final stored = _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'send',
    );
    expect(stored.id, id);
    final found = await rows(zaneClient, id);
    expect(found, hasLength(1));
    expect(found.single['sender_id'], umutClient.auth.currentUser!.id);
    expect(found.single['attachment_path'], isNotNull);
    expect(found.single['attachment_path'], startsWith('$umutZane/'));
  });

  test('the same photo sent twice (the first answer lost)', () async {
    final id = randomMessageId();
    final body = _stamp('twice');
    final first = _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'first',
    );
    final again = _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'retry',
    );
    expect(again.id, id);
    expect(again.body, first.body);
    expect(again.conversationId, umutZane);
    expect(await rows(umutClient, id), hasLength(1));
  });

  test(
    'the retry of a photo whose id belongs to someone else is refused',
    () async {
      final id = randomMessageId();
      final body = _stamp('zane wrote it');
      _ok(
        await zane.sendImage(
          conversationId: umutZane,
          image: _img(id),
          body: body,
        ),
        'zane first',
      );
      final before = await rows(zaneClient, id);
      final r = await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      );
      await expectDenied(r, 'retry of someone else');
      final after = await rows(zaneClient, id);
      expect(after, before);
    },
  );

  test('own id from chat A into chat B is refused', () async {
    final id = randomMessageId();
    final body = _stamp('own id');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'first',
    );
    final r = await umut.sendImage(
      conversationId: umutVedat,
      image: _img(id),
      body: body,
    );
    await expectDenied(r, 'own id into another chat');
    final after = await rows(umutClient, id);
    expect(after, hasLength(1));
  });

  test('id from unreadable chat is refused', () async {
    final id = randomMessageId();
    final body = _stamp('unreadable');
    _ok(
      await zane.sendImage(
        conversationId: zaneVedat,
        image: _img(id),
        body: body,
      ),
      'zane first',
    );
    final before = await rows(zaneClient, id);
    final r = await umut.sendImage(
      conversationId: umutZane,
      image: _img(id),
      body: body,
    );
    await expectDenied(r, 'unreadable chat id');
    final after = await rows(zaneClient, id);
    expect(after, before);
  });

  test('reply retry keeps the stored row', () async {
    final quoted = _ok(
      await zane.send(
        id: randomMessageId(),
        conversationId: umutZane,
        body: _stamp('quoted'),
      ),
      'quoted',
    );
    final id = randomMessageId();
    final body = _stamp('reply');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
        replyTo: quoted.id,
      ),
      'first',
    );
    final second = _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
        replyTo: quoted.id,
      ),
      'second',
    );
    expect(second.id, id);
    expect(second.replyTo, quoted.id);
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('retry with a different caption is refused', () async {
    final id = randomMessageId();
    final bodyA = _stamp('caption A');
    final bodyB = _stamp('caption B');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: bodyA,
      ),
      'first',
    );
    final r = await umut.sendImage(
      conversationId: umutZane,
      image: _img(id),
      body: bodyB,
    );
    await expectDenied(r, 'different caption');
    final after = await rows(umutClient, id);
    expect(after, hasLength(1));
    expect(after.single['body'], bodyA);
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
    final body = _stamp('reply');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
        replyTo: quotedA.id,
      ),
      'first',
    );
    final r = await umut.sendImage(
      conversationId: umutZane,
      image: _img(id),
      body: body,
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
    'a retry whose stored row has a reply but the retry has none is refused',
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
      final body = _stamp('reply');
      _ok(
        await umut.sendImage(
          conversationId: umutZane,
          image: _img(id),
          body: body,
          replyTo: quoted.id,
        ),
        'first',
      );
      final r = await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      );
      await expectDenied(r, 'retry with no reply');
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
      final body = _stamp('reply');
      _ok(
        await umut.sendImage(
          conversationId: umutZane,
          image: _img(id),
          body: body,
        ),
        'first',
      );
      final r = await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
        replyTo: quoted.id,
      );
      await expectDenied(r, 'retry with reply');
      final row = await umutClient
          .from('messages')
          .select('reply_to')
          .eq('id', id)
          .single();
      expect(row['reply_to'], isNull);
      expect(await rows(umutClient, id), hasLength(1));
    },
  );

  test(
    'a retry in the same album (same photo_group) is accepted and is one row',
    () async {
      final group = randomMessageId();
      final id = randomMessageId();
      final body = _stamp('album');
      _ok(
        await umut.sendImage(
          conversationId: umutZane,
          image: _img(id).inGroup(group),
          body: body,
        ),
        'first',
      );
      final second = _ok(
        await umut.sendImage(
          conversationId: umutZane,
          image: _img(id).inGroup(group),
          body: body,
        ),
        'second',
      );
      expect(second.photoGroup, group);
      expect(await rows(umutClient, id), hasLength(1));
    },
  );

  test('a retry with another album id is refused', () async {
    final g1 = randomMessageId();
    final g2 = randomMessageId();
    final id = randomMessageId();
    final body = _stamp('album diff');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id).inGroup(g1),
        body: body,
      ),
      'first',
    );
    final r = await umut.sendImage(
      conversationId: umutZane,
      image: _img(id).inGroup(g2),
      body: body,
    );
    await expectDenied(r, 'different album');
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('an album photo retried as a lone photo is refused', () async {
    final group = randomMessageId();
    final id = randomMessageId();
    final body = _stamp('album to lone');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id).inGroup(group),
        body: body,
      ),
      'first',
    );
    final r = await umut.sendImage(
      conversationId: umutZane,
      image: _img(id),
      body: body,
    );
    await expectDenied(r, 'album to lone');
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('a lone photo retried into an album is refused', () async {
    final group = randomMessageId();
    final id = randomMessageId();
    final body = _stamp('lone to album');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'first',
    );
    final r = await umut.sendImage(
      conversationId: umutZane,
      image: _img(id).inGroup(group),
      body: body,
    );
    await expectDenied(r, 'lone to album');
    expect(await rows(umutClient, id), hasLength(1));
  });

  test('an accepted retry leaves no extra object in storage; the stored photo and its companions stay', () async {
    final service = SupabaseClient(
      _url,
      serviceKey(),
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    addTearDown(service.dispose);
    final id = randomMessageId();
    final body = _stamp('cleanup');
    final first = _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'first',
    );
    final stored = first.attachmentPath!;
    final name = stored.substring(stored.lastIndexOf('/') + 1);
    final before = await objectNames(service, umutZane);
    expect(before, contains(name));
    final again = _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'retry',
    );
    expect(again.attachmentPath, stored);
    final after = await objectNames(service, umutZane);
    expect(
      after,
      before,
      reason: 'the retry left no extra object (photo, .t or .s) behind',
    );
    expect(after, contains(name), reason: 'the stored photo is not removed');
    expect(after, contains('$name.s'));
  });

  test('an accepted retry makes no upload and no storage delete', () async {
    final host = RequestLogHost();
    final logged = await loggedSignedIn(umutClient, host);
    addTearDown(logged.dispose);
    final repo = SupabaseChatRepository(logged);
    final id = randomMessageId();
    final body = _stamp('no upload');
    _ok(
      await umut.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'first',
    );
    final again = _ok(
      await repo.sendImage(
        conversationId: umutZane,
        image: _img(id),
        body: body,
      ),
      'retry',
    );
    expect(again.id, id);
    expect(
      host.storageWrites,
      isEmpty,
      reason: 'no upload and no delete: the stored row is found first',
    );
    expect(await rows(umutClient, id), hasLength(1));
  });
}

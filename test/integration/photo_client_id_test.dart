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

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _pw = 'integration-password';

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
    umutClient = await _signedIn('umut@integration.test');
    zaneClient = await _signedIn('zane@integration.test');
    vedatClient = await _signedIn('vedat@integration.test');
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
}

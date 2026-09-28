@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A text message carries the id the phone made for it, so a retried send
/// is idempotent (docs/DECISIONS.md, "Unsent text stays in each chat").
/// Against the real local stack: [SupabaseChatRepository.send] stores the
/// row under the client's id, and when that id is already taken (a retry
/// whose first answer was lost) it answers Ok ONLY for the member's own,
/// identical message -- same sender, same conversation, same trimmed body,
/// same reply -- and a refusal ([DeniedFailure]) for anything else, never
/// someone else's message passed off as ours.
///
/// Each "someone else's row" is made by a real member through the real
/// repository, so row-level security decides what the retry can see, as on
/// a phone.
///
/// Requires `docker compose run --rm supabase start`. Uses umut, zane and
/// vedat (supabase/seed.sql); run with --concurrency=1.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

Message _ok(Result<Message> r, String what) {
  expect(r, isA<Ok<Message>>(), reason: '$what: $r');
  return (r as Ok<Message>).value;
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
    umutZane = await direct(umut, zaneClient);
    umutVedat = await direct(umut, vedatClient);
    zaneVedat = await direct(zane, vedatClient);
  });

  tearDownAll(() async {
    await umutClient.dispose();
    await zaneClient.dispose();
    await vedatClient.dispose();
  });

  /// The rows with [id], as the member who can see the most of them does.
  Future<List<Map<String, dynamic>>> rows(SupabaseClient as, String id) async =>
      await as
          .from('messages')
          .select('id, conversation_id, sender_id, body, reply_to, created_at')
          .eq('id', id);

  test('a fresh id is stored as the row\'s id; the server still sets the '
      'time', () async {
    final id = randomMessageId();
    final before = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final stored = _ok(
      await umut.send(id: id, conversationId: umutZane, body: _stamp('fresh')),
      'send',
    );
    expect(stored.id, id);
    final found = await rows(zaneClient, id);
    expect(found, hasLength(1));
    expect(found.single['sender_id'], umutClient.auth.currentUser!.id);
    final at = DateTime.parse(found.single['created_at'] as String);
    expect(at.isAfter(before), isTrue, reason: 'created_at is the server\'s');
  });

  test('the same send twice (the first answer lost): Ok both times, the same '
      'id, one row', () async {
    final id = randomMessageId();
    final body = _stamp('twice');
    final first = _ok(
      await umut.send(id: id, conversationId: umutZane, body: body),
      'first',
    );
    final again = _ok(
      await umut.send(id: id, conversationId: umutZane, body: body),
      'retry',
    );
    expect(again.id, id);
    expect(again.body, first.body);
    expect(again.conversationId, umutZane);
    expect(await rows(umutClient, id), hasLength(1));
  });

  test(
    'the retry of a reply, and of an untrimmed body, is still ours',
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
      final body = '  ${_stamp('reply')}  ';
      _ok(
        await umut.send(
          id: id,
          conversationId: umutZane,
          body: body,
          replyTo: quoted.id,
        ),
        'first',
      );
      final again = _ok(
        await umut.send(
          id: id,
          conversationId: umutZane,
          body: body,
          replyTo: quoted.id,
        ),
        'retry',
      );
      expect(again.id, id);
      expect(again.body, body.trim());
      expect(again.replyTo, quoted.id);
      expect(await rows(umutClient, id), hasLength(1));
    },
  );

  group('an id already taken by a message that is not this one is refused', () {
    Future<void> expectRefused(
      Future<Result<Message>> retry,
      String id,
      Map<String, dynamic> unchanged,
      SupabaseClient witness,
    ) async {
      final r = await retry;
      expect(r, isA<Err<Message>>(), reason: 'passed off as ours: $r');
      final f = (r as Err<Message>).failure;
      expect(
        f is NetworkFailure && f.retryable,
        isFalse,
        reason: 'a taken id is not "no connection": retrying cannot help',
      );
      expect(f, isA<DeniedFailure>(), reason: 'got ${f.runtimeType}: $f');
      final after = await rows(witness, id);
      expect(after, hasLength(1), reason: 'no second row');
      expect(after.single, unchanged, reason: 'the row is untouched');
    }

    test('another member\'s message, same conversation, same body', () async {
      final id = randomMessageId();
      final body = _stamp('zane wrote it');
      _ok(
        await zane.send(id: id, conversationId: umutZane, body: body),
        'zane',
      );
      final row = (await rows(zaneClient, id)).single;
      await expectRefused(
        umut.send(id: id, conversationId: umutZane, body: body),
        id,
        row,
        zaneClient,
      );
    });

    test('my own message, same conversation, another body', () async {
      final id = randomMessageId();
      _ok(
        await umut.send(id: id, conversationId: umutZane, body: _stamp('one')),
        'first',
      );
      final row = (await rows(umutClient, id)).single;
      await expectRefused(
        umut.send(id: id, conversationId: umutZane, body: _stamp('two')),
        id,
        row,
        umutClient,
      );
    });

    test('my own message, same body, in another conversation', () async {
      final id = randomMessageId();
      final body = _stamp('elsewhere');
      _ok(
        await umut.send(id: id, conversationId: umutVedat, body: body),
        'first',
      );
      final row = (await rows(umutClient, id)).single;
      await expectRefused(
        umut.send(id: id, conversationId: umutZane, body: body),
        id,
        row,
        umutClient,
      );
    });

    test('my own message, same body, replying to something else', () async {
      final a = _ok(
        await zane.send(
          id: randomMessageId(),
          conversationId: umutZane,
          body: _stamp('a'),
        ),
        'a',
      );
      final b = _ok(
        await zane.send(
          id: randomMessageId(),
          conversationId: umutZane,
          body: _stamp('b'),
        ),
        'b',
      );
      final id = randomMessageId();
      final body = _stamp('which one');
      _ok(
        await umut.send(
          id: id,
          conversationId: umutZane,
          body: body,
          replyTo: a.id,
        ),
        'first',
      );
      final row = (await rows(umutClient, id)).single;
      await expectRefused(
        umut.send(id: id, conversationId: umutZane, body: body, replyTo: b.id),
        id,
        row,
        umutClient,
      );
    });

    test('a message in a conversation I am not in (invisible to me)', () async {
      final id = randomMessageId();
      final body = _stamp('not for umut');
      _ok(
        await zane.send(id: id, conversationId: zaneVedat, body: body),
        'zane',
      );
      final row = (await rows(vedatClient, id)).single;
      expect(await rows(umutClient, id), isEmpty, reason: 'precondition');
      await expectRefused(
        umut.send(id: id, conversationId: umutZane, body: body),
        id,
        row,
        vedatClient,
      );
      expect(
        await rows(zaneClient, id),
        hasLength(1),
        reason: 'nothing landed in umut\'s conversation',
      );
    });
  });

  test('an id that is not a UUID is refused, not retried as offline, and '
      'stores nothing', () async {
    final body = _stamp('bad id');
    final r = await umut.send(
      id: 'not-a-uuid',
      conversationId: umutZane,
      body: body,
    );
    expect(r, isA<Err<Message>>());
    final f = (r as Err<Message>).failure;
    expect(
      f is NetworkFailure && f.retryable,
      isFalse,
      reason: 'a server answer is never worth retrying',
    );
    final stored = await umutClient
        .from('messages')
        .select('id')
        .eq('conversation_id', umutZane)
        .eq('body', body);
    expect(stored, isEmpty);
  });
}

@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/service_key.dart';

/// [SupabaseChatRepository.search] and [SupabaseChatRepository.messagesAround]
/// against the real local stack: the real search_messages RPC and its
/// parameter names, the rows it returns parsed into [Message]s, and the
/// membership and app-access gates as a phone meets them.
///
/// Every run writes fresh text tagged with [_tag], so history left by earlier
/// runs cannot satisfy an assertion; results are read for this run's ids.
///
/// Requires a running local Supabase and SUPABASE_TEST_SERVICE_KEY (to write
/// two messages at the same instant, which no client may). Accounts
/// sofi/tarik/umut are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

/// Letters only, so it survives the fold unchanged and never looks like a
/// wildcard: unique per run.
final _tag = () {
  var n = DateTime.now().microsecondsSinceEpoch;
  final b = StringBuffer('q');
  while (n > 0) {
    b.writeCharCode(0x61 + n % 26);
    n ~/= 26;
  }
  return b.toString();
}();

List<Message> _ok(Result<List<Message>> r) {
  expect(r, isA<Ok<List<Message>>>(), reason: 'refused: $r');
  return (r as Ok<List<Message>>).value;
}

void main() {
  SupabaseClient? sofiClient;
  SupabaseClient? tarikClient;
  SupabaseClient? umutClient;
  SupabaseClient? service;
  final laterClients = <SupabaseClient>[];
  late SupabaseChatRepository sofi;
  late SupabaseChatRepository tarik;
  late SupabaseChatRepository umut;
  late String sofiId;
  late String sofiTarik;
  late String umutTarik;

  setUpAll(() async {
    sofiClient = await _signedIn('sofi@integration.test');
    tarikClient = await _signedIn('tarik@integration.test');
    umutClient = await _signedIn('umut@integration.test');
    service = _client(serviceKey());
    sofi = SupabaseChatRepository(sofiClient!);
    tarik = SupabaseChatRepository(tarikClient!);
    umut = SupabaseChatRepository(umutClient!);
    sofiId = sofiClient!.auth.currentUser!.id;
    sofiTarik = (await sofi.startDirectConversation(
      tarikClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
    umutTarik = (await umut.startDirectConversation(
      tarikClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
  });

  tearDownAll(() async {
    for (final c in [
      sofiClient,
      tarikClient,
      umutClient,
      service,
      ...laterClients,
    ]) {
      await c?.dispose();
    }
  });

  Future<Message> send(
    SupabaseChatRepository as,
    String conversation,
    String body,
  ) async {
    final r = await as.send(
      id: randomMessageId(),
      conversationId: conversation,
      body: body,
    );
    expect(r, isA<Ok<Message>>(), reason: 'send failed: $r');
    return (r as Ok<Message>).value;
  }

  /// A fresh group of sofi and tarik: a history holding only what the test
  /// writes, for exact windows.
  Future<String> freshGroup(String title) async {
    final r = await sofi.startGroupConversation(
      title: title,
      memberIds: [tarikClient!.auth.currentUser!.id],
    );
    expect(r, isA<Ok<String>>(), reason: 'group refused: $r');
    return (r as Ok<String>).value;
  }

  group('search', () {
    test(
      'finds every Turkish spelling, newest first, as full messages',
      () async {
        final a = await send(sofi, sofiTarik, 'İstanbul $_tag capital');
        final b = await send(tarik, sofiTarik, 'ISTANBUL $_tag upper');
        final c = await send(sofi, sofiTarik, 'ıstanbul $_tag dotless');
        final d = await send(tarik, sofiTarik, 'going to istanbul $_tag');

        for (final query in [
          'istanbul $_tag',
          'İSTANBUL $_tag',
          'ıstanbul $_tag',
        ]) {
          final hits = _ok(await sofi.search(query));
          expect(hits.map((m) => m.id), [
            d.id,
            c.id,
            b.id,
            a.id,
          ], reason: '"$query": every spelling, newest first');
        }

        final hits = _ok(await tarik.search('istanbul $_tag'));
        final first = hits.first;
        expect(first.id, d.id);
        expect(first.conversationId, sofiTarik);
        expect(first.senderId, tarikClient!.auth.currentUser!.id);
        expect(first.body, 'going to istanbul $_tag');
        expect(
          first.createdAt.isAtSameMomentAs(d.createdAt),
          isTrue,
          reason: 'created_at is parsed as the same instant send returned',
        );
        expect(first.isDeleted, isFalse);
        expect(first.isEdited, isFalse);
        expect(first.forwarded, isFalse);
      },
    );

    test('matches a substring, case-insensitively', () async {
      final m = await send(sofi, sofiTarik, 'Dinner $_tag at eight');
      final hits = _ok(await tarik.search('DIN'));
      expect(hits.map((h) => h.id), contains(m.id));
      final exact = _ok(await tarik.search('inner ${_tag.toUpperCase()} AT'));
      expect(exact.map((h) => h.id), [m.id]);
    });

    test('%, _ and \\ are literal characters, never wildcards', () async {
      final pct = await send(sofi, sofiTarik, '$_tag 100% sure');
      await send(sofi, sofiTarik, '$_tag 100 percent');
      final und = await send(sofi, sofiTarik, '$_tag a_b');
      await send(sofi, sofiTarik, '$_tag axb');
      final bsl = await send(sofi, sofiTarik, r'C:\sys ' + _tag);
      await send(sofi, sofiTarik, 'plain sys $_tag');

      Future<List<String>> ids(String q) async => [
        for (final m in _ok(await sofi.search(q)))
          if (m.body.contains(_tag)) m.id,
      ];
      expect(await ids('$_tag 100%'), [pct.id]);
      expect(await ids('00% su'), [pct.id]);
      expect(await ids('$_tag a_'), [und.id]);
      expect(await ids(r'\sys ' + _tag), [bsl.id]);
      expect(await ids('%%%'), isEmpty);
      expect(await ids('___'), isEmpty);
    });

    test(
      'a query under three characters is Ok and empty, never a failure',
      () async {
        await send(sofi, sofiTarik, 'ab $_tag');
        for (final q in [
          '', ' ', 'a', ' a ', '\n', 'ab', ' ab ', 'ab\n', //
          '%%%', '...', '!!!', '😂😂😂', 'a..',
        ]) {
          expect(
            await sofi.search(q),
            isA<Ok<List<Message>>>().having((r) => r.value, 'value', isEmpty),
            reason: '"$q"',
          );
        }
        expect(
          await sofi.search('ab', conversationId: sofiTarik),
          isA<Ok<List<Message>>>().having((r) => r.value, 'value', isEmpty),
        );
        expect(
          _ok(await sofi.search('ab ', conversationId: sofiTarik)),
          isEmpty,
          reason: 'trimmed first',
        );
        expect(
          _ok(await sofi.search('ab ${_tag[0]}', conversationId: sofiTarik)),
          isNotEmpty,
          reason: 'three characters do search (control)',
        );
      },
    );

    test('scoped to a conversation when given, every one when not', () async {
      final mine = await send(sofi, sofiTarik, 'scope $_tag sofi');
      final theirs = await send(umut, umutTarik, 'scope $_tag umut');

      final tarikAll = _ok(await tarik.search('scope $_tag'));
      expect(tarikAll.map((m) => m.id), [theirs.id, mine.id]);

      final tarikScoped = _ok(
        await tarik.search('scope $_tag', conversationId: sofiTarik),
      );
      expect(tarikScoped.map((m) => m.id), [mine.id]);
    });

    test('a conversation the caller is not in gives nothing, omitted or '
        'named', () async {
      final secret = await send(sofi, sofiTarik, 'secret $_tag');
      // Control: umut's own search reaches the server and works.
      final own = await send(umut, umutTarik, 'umut secret $_tag');
      expect(_ok(await umut.search('secret $_tag')).map((m) => m.id), [own.id]);

      expect(
        _ok(await umut.search('secret $_tag')).map((m) => m.id),
        isNot(contains(secret.id)),
      );
      expect(
        _ok(await umut.search('secret $_tag', conversationId: sofiTarik)),
        isEmpty,
      );
      expect(
        _ok(
          await umut.search(
            'secret $_tag',
            conversationId: '00000000-0000-0000-0000-00000000dead',
          ),
        ),
        isEmpty,
        reason: 'a conversation that does not exist',
      );
    });

    test('deleted messages never match; an edited one matches its current '
        'text only', () async {
      final gone = await send(sofi, sofiTarik, 'gone $_tag');
      expect(await sofi.deleteForEveryone(gone), isA<Ok<void>>());
      expect(_ok(await tarik.search('gone $_tag')), isEmpty);

      final typo = await send(sofi, sofiTarik, 'teh $_tag typo');
      expect(
        await sofi.editMessage(typo, 'the $_tag fixed'),
        isA<Ok<Message>>(),
      );
      expect(_ok(await tarik.search('teh $_tag')), isEmpty);
      final hits = _ok(await tarik.search('the $_tag'));
      expect(hits.map((m) => m.id), [typo.id]);
      expect(hits.single.body, 'the $_tag fixed');
      expect(hits.single.isEdited, isTrue, reason: 'edited_at is parsed');
    });

    test('at most 50 hits, the newest 50', () async {
      final room = await freshGroup('cap $_tag');
      final sent = <Message>[];
      for (var i = 0; i < 55; i++) {
        sent.add(await send(sofi, room, 'cap $_tag n$i'));
      }
      final hits = _ok(await sofi.search('cap $_tag'));
      expect(hits, hasLength(50));
      expect(
        hits.map((m) => m.id),
        sent.reversed.take(50).map((m) => m.id),
        reason: 'newest first, and the newest 50 of them',
      );
    });

    test('a replaced session gets nothing, while its newer one does', () async {
      final m = await send(sofi, sofiTarik, 'session $_tag');
      // Umut is not in sofiTarik; tarik is. Tarik's own old client is what
      // app access must refuse once his second sign-in takes over.
      final oldTarik = tarikClient!;
      final newTarikClient = await _signedIn('tarik@integration.test');
      laterClients.add(newTarikClient);
      final newTarik = SupabaseChatRepository(newTarikClient);

      expect(_ok(await newTarik.search('session $_tag')).map((h) => h.id), [
        m.id,
      ], reason: 'control: the active device finds it');
      final stale = await SupabaseChatRepository(oldTarik)
          .search('session $_tag');
      expect(
        stale is Ok<List<Message>> && stale.value.isNotEmpty,
        isFalse,
        reason: 'the replaced device must get nothing: $stale',
      );
      // The suite's tarik is the new session from here on.
      tarik = newTarik;
    });
  });

  group('messagesAround', () {
    late String room;
    late List<Message> sent;

    setUpAll(() async {
      room = await freshGroup('around $_tag');
      sent = [];
      for (var i = 0; i < 120; i++) {
        sent.add(await send(i.isEven ? sofi : tarik, room, 'w$i $_tag'));
      }
    });

    List<String> idsOf(Iterable<Message> ms) => [for (final m in ms) m.id];

    test('50 older, the anchor, 50 newer, oldest first', () async {
      final anchor = sent[60];
      final window = _ok(await sofi.messagesAround(room, anchor));
      expect(idsOf(window), idsOf(sent.sublist(10, 111)));
      expect(window[50].id, anchor.id);
      expect(window[50].body, 'w60 $_tag');
      expect(window[50].createdAt.isAtSameMomentAs(anchor.createdAt), isTrue);
    });

    test('near the start: every older message there is', () async {
      final window = _ok(await tarik.messagesAround(room, sent[3]));
      expect(idsOf(window), idsOf(sent.sublist(0, 54)));
    });

    test('the newest: 50 older and nothing after it', () async {
      final window = _ok(await sofi.messagesAround(room, sent.last));
      expect(idsOf(window), idsOf(sent.sublist(69, 120)));
    });

    test('a non-member gets no rows', () async {
      final r = await umut.messagesAround(room, sent[60]);
      expect(
        r is Ok<List<Message>> && r.value.isNotEmpty,
        isFalse,
        reason: 'umut is not in the group: $r',
      );
    });

    test('a message at the very same instant as the anchor is not '
        'duplicated as the anchor', () async {
      final quiet = await freshGroup('twin $_tag');
      final before = await send(sofi, quiet, 'before $_tag');
      final anchor = await send(sofi, quiet, 'anchor $_tag');
      final after = await send(sofi, quiet, 'after $_tag');
      await service!.from('messages').insert({
        'conversation_id': quiet,
        'sender_id': sofiId,
        'body': 'twin $_tag',
        'created_at': anchor.createdAt.toUtc().toIso8601String(),
      });

      final window = _ok(await sofi.messagesAround(quiet, anchor));
      expect(window.where((m) => m.id == anchor.id), hasLength(1));
      expect(window.first.id, before.id, reason: 'strictly older first');
      expect(window.last.id, after.id, reason: 'strictly newer last');
    });
  });
}

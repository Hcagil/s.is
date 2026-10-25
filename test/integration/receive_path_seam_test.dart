@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/message_opener.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/supabase_key_directory.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/drift_stores.dart';
import '../support/key_directory_fakes.dart';
import '../support/reach.dart';

/// The receive path against the real local Supabase (Private Chats 4a Group
/// D): ana's real engine locks a text, SupabaseEncryptedMessageRepository
/// stores it, and ben's SupabaseChatRepository selects ciphertext + olm_type,
/// maps them and runs them through the opener: a qa recording opener (what
/// the repository hands over), ben's REAL StoreMessageOpener over his real
/// engine and store (the text comes back), and a qa scripted opener for the
/// live-row rules (order kept, a failing open never breaks the stream,
/// reopened rows reach incoming and incomingAll).
///
/// Fixtures: es-ana and es-ben (supabase/seed.sql allowlist, they publish
/// keys). Written from the contract, never from the implementation.
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
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _id(SupabaseClient c) => c.auth.currentUser!.id;

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok, got $r');
  return (r as Ok<T>).value;
}

/// One phone: a real store file and a real Olm account published for
/// [client]. Its one-time keys stay known here, so ana can open a session to
/// ben without a (rate limited) server claim.
class _Phone {
  _Phone(this.client, this.dir, this.store, this.engine, this.claim);

  final SupabaseClient client;
  final Directory dir;
  final DriftMessageStore store;
  final DriftSessionEngine engine;
  final ClaimedKeys Function() claim;

  static Future<_Phone> make(SupabaseClient client) async {
    final dir = await Directory.systemTemp.createTemp('rp-');
    final store = driftStore(_id(client), dir, 'ef' * 32);
    final olm = OlmKeyEngine();
    final account = await olm.create();
    account.generateOneTimeKeys(5);
    account.generateFallbackKey();
    final otks = account.unpublishedOneTimeKeys;
    final sig = account.sign(
      deviceStatement(_id(client), account.identityKey, account.signingKey),
    );
    _ok(
      await SupabaseKeyDirectory(client).publish(
        identityKey: account.identityKey,
        signingKey: account.signingKey,
        deviceSignature: sig,
        oneTimeKeys: otks,
        fallbackKey: account.unpublishedFallbackKey,
      ),
    );
    account.markPublished();
    expect(
      await DriftOlmPickleStore(store).save(account.pickle(FakePickleKeys.key)),
      isTrue,
    );
    final engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: FakePickleKeys(),
    );
    var next = 0;
    ClaimedKeys claim() => ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: sig,
      oneTimeKey: otks[next++],
      isFallback: false,
    );
    return _Phone(client, dir, store, engine, claim);
  }

  Future<void> close() async {
    await store.close();
    await dir.delete(recursive: true);
  }
}

/// Hands rows back untouched and keeps what it was given.
class _Recording implements MessageOpener {
  final seen = <Message>[];

  /// Message id -> the fresh flag of every open that carried it.
  final freshOf = <String, List<bool>>{};
  @override
  Future<List<Message>> open(List<Message> rows, {bool fresh = false}) async {
    seen.addAll(rows);
    for (final m in rows) {
      (freshOf[m.id] ??= []).add(fresh);
    }
    return rows;
  }

  @override
  Stream<Message> get reopened => const Stream.empty();

  final forgotten = <String>[];
  @override
  void forget(String id) => forgotten.add(id);
}

/// Opens each row by id after [delay] of that id; throws for [boom]; rows
/// not in [delay] pass unchanged. [reopen] pushes onto reopened.
class _Scripted implements MessageOpener {
  final delay = <String, Duration>{};
  final boom = <String>{};
  final _reopened = StreamController<Message>.broadcast();

  void reopen(Message m) => _reopened.add(m);

  @override
  Future<List<Message>> open(List<Message> rows, {bool fresh = false}) async =>
      [
        for (final m in rows)
          if (boom.contains(m.id))
            throw StateError('open failed')
          else if (delay[m.id] case final d?)
            await Future<void>.delayed(d)
                .then((_) => m.withPlain('opened', null))
          else
            m,
      ];

  @override
  Stream<Message> get reopened => _reopened.stream;

  final forgotten = <String>[];
  @override
  void forget(String id) => forgotten.add(id);
}

void main() {
  late SupabaseClient ana, ben;
  late _Phone anaPhone, benPhone;
  late String ab;
  var sessionMade = false;

  setUpAll(() async {
    ana = await _signedIn('es-ana@mail.test');
    ben = await _signedIn('es-ben@mail.test');
    anaPhone = await _Phone.make(ana);
    benPhone = await _Phone.make(ben);
    final repo = SupabaseChatRepository(ana);
    var r = await repo.startDirectConversation(_id(ben));
    if (r is Err) {
      await findTag(ana, await tagOf(ben), id: _id(ben));
      r = await repo.startDirectConversation(_id(ben));
    }
    ab = _ok(r);
  });

  tearDownAll(() async {
    await anaPhone.close();
    await benPhone.close();
    await ana.dispose();
    await ben.dispose();
  });

  /// ana locks [text] for a new row and stores it on the server.
  Future<({String id, String ciphertext, int olmType})> send(
    String text,
  ) async {
    if (!sessionMade) {
      _ok(await anaPhone.engine.createOutbound(_id(ben), benPhone.claim()));
      sessionMade = true;
    }
    final benKey = _ok(await SupabaseKeyDirectory(ana).identity(_id(ben)));
    final id = randomMessageId();
    final l = _ok(
      await anaPhone.engine.encrypt(
        _id(ben),
        encodeEnvelope(id: id, text: text),
        peerIdentityKey: benKey!.identityKey,
      ),
    );
    _ok(
      await SupabaseEncryptedMessageRepository(ana).send(
        id: id,
        conversationId: ab,
        ciphertext: l.ciphertext,
        olmType: l.olmType,
      ),
    );
    return (id: id, ciphertext: l.ciphertext, olmType: l.olmType);
  }

  test('messages() selects ciphertext and olm_type and maps them onto the '
      'row handed to the opener', () async {
    final sent = await send('mapped through');
    final rec = _Recording();
    _ok(await SupabaseChatRepository(ben, opener: rec).messages(ab));
    final row = rec.seen.firstWhere((m) => m.id == sent.id);
    expect(row.ciphertext, sent.ciphertext);
    expect(row.olmType, sent.olmType);
    expect(row.body, lockedBodyPlaceholder);
    expect(row.senderId, _id(ana));
  });

  test('ben\'s real opener: messages() returns the plaintext, never the '
      'ciphertext, and his store holds it', () async {
    final sent = await send('the real text 😀');
    final opener = StoreMessageOpener(
      me: () => _id(ben),
      engine: () => benPhone.engine,
      store: () => benPhone.store,
      peerKey: SupabaseKeyDirectory(ben).identity,
    );
    addTearDown(opener.dispose);
    final repo = SupabaseChatRepository(ben, opener: opener);
    final rows = _ok(await repo.messages(ab));
    final m = rows.firstWhere((m) => m.id == sent.id);
    expect(m.body, 'the real text 😀');
    expect(m.ciphertext, isNull);
    for (final r in rows) {
      expect(r.ciphertext, isNull, reason: '${r.id} came back locked');
    }
    final stored = await benPhone.store.newest(ab, limit: 200);
    expect(stored.firstWhere((s) => s.id == sent.id).body, 'the real text 😀');
    // A second fetch must not decrypt again (Olm could not) and still reads.
    final again = _ok(await repo.messages(ab));
    expect(again.firstWhere((x) => x.id == sent.id).body, 'the real text 😀');
  });

  test('live rows are opened one after the other (order kept) and a failing '
      'open never breaks the stream', () async {
    final opener = _Scripted();
    final repo = SupabaseChatRepository(ben, opener: opener);
    final stream = _ok(await repo.incoming(ab));
    final got = <String>[];
    final sub = stream.listen((m) => got.add(m.id));
    addTearDown(sub.cancel);
    final ids = <String>[];
    // Open delays reversed: a parallel open would deliver the second first.
    final slow = await send('one');
    opener.delay[slow.id] = const Duration(milliseconds: 600);
    final fast = await send('two');
    opener.delay[fast.id] = const Duration(milliseconds: 5);
    final bad = await send('three');
    opener.boom.add(bad.id);
    final after = await send('four');
    opener.delay[after.id] = const Duration(milliseconds: 5);
    ids.addAll([slow.id, fast.id, after.id]);
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!got.contains(after.id) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(got.where(ids.contains).toList(), ids);
  });

  test(
    'a reopened row reaches incoming of its chat (only) and incomingAll',
    () async {
      final opener = _Scripted();
      final repo = SupabaseChatRepository(ben, opener: opener);
      final one = <Message>[];
      final all = <Message>[];
      final s1 = _ok(await repo.incoming(ab)).listen(one.add);
      final s2 = _ok(await repo.incomingAll()).listen(all.add);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);
      final m = Message(
        id: randomMessageId(),
        conversationId: ab,
        senderId: _id(ana),
        body: 'opened later',
        createdAt: DateTime.now().toUtc(),
      );
      // A row of another chat first: it must not reach this chat's stream.
      opener.reopen(
        Message(
          id: randomMessageId(),
          conversationId: 'not-$ab',
          senderId: _id(ana),
          body: 'elsewhere',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      opener.reopen(m);
      final end = DateTime.now().add(const Duration(seconds: 5));
      while ((one.isEmpty || all.length < 2) && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(one.map((x) => (x.id, x.body)), [(m.id, 'opened later')]);
      expect(all.map((x) => x.body), ['elsewhere', 'opened later']);
    },
  );

  test('only rows that just arrived are opened as fresh: live inserts and '
      'the change feed; the first page, older pages and the page around a '
      'message are not', () async {
    final rec = _Recording();
    final repo = SupabaseChatRepository(ben, opener: rec);
    final live = _ok(await repo.incoming(ab));
    final got = <String>[];
    final sub = live.listen((m) => got.add(m.id));
    addTearDown(sub.cancel);
    final cursor = ChangeCursor(
      DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      '00000000-0000-0000-0000-000000000000',
    );
    final sent = await send('fresh or not');
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!got.contains(sent.id) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(got, contains(sent.id), reason: 'the live insert arrived');
    expect(rec.freshOf[sent.id], [true], reason: 'live insert');

    Future<List<bool>> flags(Future<void> Function() read) async {
      rec.freshOf.clear();
      await read();
      expect(rec.freshOf, contains(sent.id), reason: 'the read returned it');
      return rec.freshOf[sent.id]!;
    }

    var page = <Message>[];
    expect(await flags(() async => page = _ok(await repo.messages(ab))), [
      false,
    ], reason: 'messages (first page)');
    expect(
      await flags(
        () async => _ok(
          await repo.messagesBefore(
            ab,
            DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        ),
      ),
      [false],
      reason: 'messagesBefore',
    );
    final anchor = page.firstWhere((m) => m.id == sent.id);
    expect(
      await flags(() async => _ok(await repo.messagesAround(ab, anchor))),
      everyElement(isFalse),
      reason: 'messagesAround',
    );
    expect(
      await flags(() async {
        var c = cursor;
        while (true) {
          final p = _ok(await repo.changesSince(c));
          if (p.last == null) break;
          c = p.last!;
        }
      }),
      everyElement(isTrue),
      reason: 'changesSince',
    );
  });
}

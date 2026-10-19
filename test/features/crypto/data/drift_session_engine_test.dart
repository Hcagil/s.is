// DriftSessionEngine with two REAL Olm engines (OlmKeyEngine over the compiled
// vodozemac library, loaded by the engine itself as in the app) and two REAL
// encrypted store files. Written from the SessionEngine contract
// (lib/features/crypto/domain/session_engine.dart), never from the
// implementation. Failures inside the transaction are forced with SQLite
// triggers in the real file.
import 'dart:convert';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';

import '../../chat/data/store/store_harness.dart';

final class _FixedPickleKey implements PickleKeyStore {
  _FixedPickleKey(this.key);
  final List<int> key;
  @override
  Future<List<int>> loadOrCreate() async => key;
  @override
  Future<void> delete() async {}
}

/// One phone: its own store file, Olm account, pickle key and session engine.
final class Phone {
  Phone._(this.userId, this.store, this.engine, this.keys);

  final String userId;
  final DriftMessageStore store;
  final DriftSessionEngine engine;
  final ClaimedKeys Function() keys;

  static Future<Phone> make(String userId, {int oneTimeKeys = 5}) async {
    final h = await StoreHarness.create();
    final store = h.open(owner: userId, key: await h.newKey());
    addTearDown(store.close);
    final olm = OlmKeyEngine();
    final pk = List<int>.generate(32, (i) => (i * 7 + userId.length) % 256);
    final account = await olm.create();
    account.generateOneTimeKeys(oneTimeKeys);
    final otks = account.unpublishedOneTimeKeys;
    account.markPublished();
    expect(await DriftOlmPickleStore(store).save(account.pickle(pk)), isTrue);
    var clock = 0;
    final engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: _FixedPickleKey(pk),
      now: () => DateTime.utc(2026, 3, 1).add(Duration(seconds: ++clock)),
    );
    var next = 0;
    ClaimedKeys keys() => ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: account.sign(
        deviceStatement(userId, account.identityKey, account.signingKey),
      ),
      oneTimeKey: otks[next++],
      isFallback: false,
    );
    final p = Phone._(userId, store, engine, keys);
    p.identityKey = account.identityKey;
    return p;
  }

  late final String identityKey;

  Future<void> exec(String statement) =>
      store.run<void>(null, (db) => db.customStatement(statement));

  /// Every stored session row, the account pickle and every message body.
  Future<List<String>> snapshot() => store.run<List<String>>(
    ['store closed'],
    (db) async => [
      for (final r
          in await db
              .customSelect(
                'SELECT session_id, peer_user_id, peer_identity_key, pickle, '
                'last_used_at FROM olm_sessions ORDER BY session_id',
              )
              .get())
        'session ${r.data}',
      for (final r
          in await db
              .customSelect("SELECT value FROM meta WHERE key = 'olm_account'")
              .get())
        'account ${r.data}',
      for (final r
          in await db
              .customSelect(
                'SELECT id, body, body_folded FROM messages ORDER BY id',
              )
              .get())
        'message ${r.data}',
    ],
  );

  Future<String?> accountPickle() => DriftOlmPickleStore(store).load();

  Future<List<Map<String, Object?>>> sessions() => store.run(
    const [],
    (db) async => [
      for (final r
          in await db
              .customSelect(
                'SELECT session_id, peer_user_id, peer_identity_key, last_used_at '
                'FROM olm_sessions ORDER BY session_id',
              )
              .get())
        r.data,
    ],
  );

  Future<String?> body(String messageId) => store.run<String?>(
    null,
    (db) async =>
        (await db
                .customSelect(
                  'SELECT body FROM messages WHERE id = ?',
                  variables: [Variable.withString(messageId)],
                )
                .getSingleOrNull())
            ?.read<String>('body'),
  );

  /// A stored placeholder row, as the sync writes it before decryption.
  Future<void> placeholder(String id, {String sender = 'alice'}) =>
      store.upsertAll([msg(id, sender: sender, body: 'locked')]);
}

T ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok, got $r');
  return (r as Ok<T>).value;
}

Failure err(Result<Object?> r) {
  expect(r, isA<Err<Object?>>(), reason: 'expected Err, got $r');
  return (r as Err<Object?>).failure;
}

String tamper(String b64, {int at = -1}) {
  final bytes = base64Decode(b64);
  final i = at < 0 ? bytes.length + at : at;
  bytes[i] ^= 0x01;
  return base64Encode(bytes);
}

void main() {
  // Each phone has its own file; two StoreDatabase instances are intended.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Phone alice;
  late Phone bob;

  setUp(() async {
    alice = await Phone.make('alice');
    bob = await Phone.make('bob');
  });

  /// Alice opens a session to Bob and locks [text]; the first message.
  Future<LockedText> first([String text = 'merhaba']) async {
    ok(await alice.engine.createOutbound('bob', bob.keys()));
    return ok(await alice.engine.encrypt('bob', text));
  }

  Future<Result<String>> bobOpens(
    LockedText m, {
    PlaintextSave? save,
    String from = 'alice',
    String? identityKey,
  }) => bob.engine.decrypt(
    peerUserId: from,
    peerIdentityKey: identityKey ?? alice.identityKey,
    ciphertext: m.ciphertext,
    olmType: m.olmType,
    save: save,
  );

  Future<Result<String>> aliceOpens(LockedText m) => alice.engine.decrypt(
    peerUserId: 'bob',
    peerIdentityKey: bob.identityKey,
    ciphertext: m.ciphertext,
    olmType: m.olmType,
  );

  /// A session both ways: Bob opened Alice's first message and Alice his reply.
  Future<void> established() async {
    ok(await bobOpens(await first()));
    ok(await aliceOpens(ok(await bob.engine.encrypt('alice', 'selam'))));
  }

  group('round trip', () {
    test('outbound, pre-key first message (type 0), decrypt makes the '
        'inbound session', () async {
      expect(await alice.engine.hasSession('bob'), isFalse);
      final id = ok(await alice.engine.createOutbound('bob', bob.keys()));
      expect(await alice.engine.hasSession('bob'), isTrue);

      final m = ok(await alice.engine.encrypt('bob', 'merhaba dünya'));
      expect(m.olmType, 0, reason: 'first message must be pre-key');
      expect(m.sessionId, id);
      expect(m.ciphertext, isNot(contains('merhaba')));

      expect(await bob.engine.hasSession('alice'), isFalse);
      expect(ok(await bobOpens(m)), 'merhaba dünya');
      expect(await bob.engine.hasSession('alice'), isTrue);
      final rows = await bob.sessions();
      expect(rows, hasLength(1));
      expect(rows.single['session_id'], id, reason: 'same session id');
      expect(rows.single['peer_user_id'], 'alice');
      expect(rows.single['peer_identity_key'], alice.identityKey);
    });

    test(
      'createInbound opens the pre-key message and stores the session',
      () async {
        final m = await first('ilk');
        final r = await bob.engine.createInbound(
          peerUserId: 'alice',
          peerIdentityKey: alice.identityKey,
          ciphertext: m.ciphertext,
          olmType: m.olmType,
        );
        expect(ok(r), 'ilk');
        expect(await bob.engine.hasSession('alice'), isTrue);
        expect((await bob.sessions()).single['session_id'], m.sessionId);
      },
    );

    test('a reply switches to type 1, both ways', () async {
      ok(await bobOpens(await first()));
      final reply = ok(await bob.engine.encrypt('alice', 'selam'));
      expect(reply.olmType, 1, reason: 'inbound side sends normal');
      expect(ok(await aliceOpens(reply)), 'selam');

      final after = ok(await alice.engine.encrypt('bob', 'nasılsın'));
      expect(after.olmType, 1, reason: 'reply received: no more pre-key');
      expect(ok(await bobOpens(after)), 'nasılsın');
    });

    test(
      'before any reply every message stays pre-key and each opens',
      () async {
        final a = await first('bir');
        final b = ok(await alice.engine.encrypt('bob', 'iki'));
        expect(b.olmType, 0);
        expect(b.sessionId, a.sessionId);
        expect(ok(await bobOpens(a)), 'bir');
        expect(ok(await bobOpens(b)), 'iki', reason: 'matched by session id');
        expect(await bob.sessions(), hasLength(1), reason: 'session reused');
      },
    );

    test('several messages out of order all open', () async {
      await established();
      final ms = [
        for (final t in ['m1', 'm2', 'm3', 'm4'])
          ok(await alice.engine.encrypt('bob', t)),
      ];
      expect(ok(await bobOpens(ms[3])), 'm4');
      expect(ok(await bobOpens(ms[0])), 'm1');
      expect(ok(await bobOpens(ms[2])), 'm3');
      expect(ok(await bobOpens(ms[1])), 'm2');
    });
  });

  group('failures', () {
    test('no session: decrypt type 1 and encrypt are SessionPending', () async {
      await established();
      final m = ok(await alice.engine.encrypt('bob', 'x'));
      // Bob's phone that never saw the first message.
      final fresh = await Phone.make('bob2');
      final r = await fresh.engine.decrypt(
        peerUserId: 'alice',
        peerIdentityKey: alice.identityKey,
        ciphertext: m.ciphertext,
        olmType: 1,
      );
      expect(err(r), isA<SessionPendingFailure>());
      expect(
        err(await fresh.engine.encrypt('alice', 'x')),
        isA<SessionPendingFailure>(),
      );
      expect(await fresh.sessions(), isEmpty);
    });

    test('duplicate delivery of a normal message is Unreadable, nothing '
        'written', () async {
      await established();
      final m = ok(await alice.engine.encrypt('bob', 'bir kez'));
      expect(ok(await bobOpens(m)), 'bir kez');
      final before = await bob.snapshot();
      expect(err(await bobOpens(m)), isA<UnreadableMessageFailure>());
      expect(await bob.snapshot(), before);
    });

    test('duplicate delivery of the pre-key message is Unreadable and keeps '
        'the stored session', () async {
      final m = await first();
      ok(await bobOpens(m));
      final before = await bob.snapshot();
      expect(err(await bobOpens(m)), isA<UnreadableMessageFailure>());
      expect(await bob.snapshot(), before, reason: 'session replaced');
    });

    test('tampered normal ciphertext is Unreadable, nothing written, and the '
        'real message still opens', () async {
      await established();
      await bob.placeholder('m1');
      final m = ok(await alice.engine.encrypt('bob', 'gizli'));
      final before = await bob.snapshot();
      for (final at in [-1, 10]) {
        final bad = LockedText(
          ciphertext: tamper(m.ciphertext, at: at),
          olmType: 1,
          sessionId: m.sessionId,
        );
        expect(
          err(await bobOpens(bad, save: const PlaintextSave('m1', 'gizli'))),
          isA<UnreadableMessageFailure>(),
        );
        expect(await bob.snapshot(), before, reason: 'written on failure');
      }
      expect(await bob.body('m1'), 'locked');
      expect(ok(await bobOpens(m)), 'gizli');
    });

    test(
      'tampered pre-key ciphertext is Unreadable, no session made',
      () async {
        final m = await first();
        final before = await bob.snapshot();
        final bad = LockedText(
          ciphertext: tamper(m.ciphertext),
          olmType: 0,
          sessionId: m.sessionId,
        );
        expect(err(await bobOpens(bad)), isA<UnreadableMessageFailure>());
        expect(await bob.snapshot(), before);
        expect(await bob.engine.hasSession('alice'), isFalse);
        expect(ok(await bobOpens(m)), 'merhaba', reason: 'one-time key spent');
      },
    );

    test('bad base64 and wrong type are Unreadable, nothing written', () async {
      final m = await first();
      final before = await bob.snapshot();
      expect(
        err(
          await bobOpens(
            const LockedText(ciphertext: '%%%', olmType: 0, sessionId: 's'),
          ),
        ),
        isA<UnreadableMessageFailure>(),
      );
      expect(
        err(
          await bob.engine.createInbound(
            peerUserId: 'alice',
            peerIdentityKey: alice.identityKey,
            ciphertext: m.ciphertext,
            olmType: 1,
          ),
        ),
        isA<UnreadableMessageFailure>(),
      );
      expect(await bob.snapshot(), before);
    });

    test(
      'the wrong peer identity key does not open the pre-key message',
      () async {
        final m = await first();
        final mallory = await Phone.make('mallory');
        final before = await bob.snapshot();
        for (final call in [
          () => bobOpens(m, identityKey: mallory.identityKey),
          () => bob.engine.createInbound(
            peerUserId: 'alice',
            peerIdentityKey: mallory.identityKey,
            ciphertext: m.ciphertext,
            olmType: 0,
          ),
        ]) {
          expect(err(await call()), isA<UnreadableMessageFailure>());
          expect(await bob.snapshot(), before, reason: 'written on failure');
        }
        expect(ok(await bobOpens(m)), 'merhaba');
      },
    );

    test('a session id that belongs to another peer is never used', () async {
      await established();
      final normal = ok(await alice.engine.encrypt('bob', 'x'));
      expect(normal.olmType, 1);
      final pre = await first('ikinci oturum');
      ok(await bobOpens(pre));
      // Not yet delivered to Bob; its session id is stored, for Alice.
      final pre2 = ok(await alice.engine.encrypt('bob', 'üçüncü'));
      expect(pre2.olmType, 0);
      expect(pre2.sessionId, pre.sessionId);
      final before = await bob.snapshot();

      // Mallory forwards Alice's messages as her own.
      expect(
        err(await bobOpens(normal, from: 'mallory')),
        isA<SessionPendingFailure>(),
        reason: "Alice's session tried for Mallory",
      );
      expect(
        err(await bobOpens(pre2, from: 'mallory')),
        isA<UnreadableMessageFailure>(),
        reason: "Alice's session matched by id for Mallory",
      );
      expect(await bob.snapshot(), before);
      expect(await bob.engine.hasSession('mallory'), isFalse);
      expect(ok(await bobOpens(pre2)), 'üçüncü', reason: 'Alice still opens');
    });

    test('a failed attempt over several sessions leaves every pickle '
        'byte-identical', () async {
      await established();
      ok(await bobOpens(await first('ikinci')));
      expect(await bob.sessions(), hasLength(2));
      final m = ok(await alice.engine.encrypt('bob', 'x'));
      final before = await bob.snapshot();
      final bad = LockedText(
        ciphertext: tamper(m.ciphertext),
        olmType: m.olmType,
        sessionId: m.sessionId,
      );
      expect(err(await bobOpens(bad)), isA<UnreadableMessageFailure>());
      expect(await bob.snapshot(), before);
    });

    test('createOutbound with keys that do not verify is DeviceKeysFailure, '
        'nothing stored', () async {
      final k = bob.keys();
      final forged = ClaimedKeys(
        identityKey: k.identityKey,
        signingKey: k.signingKey,
        deviceSignature: k.deviceSignature,
        oneTimeKey: k.oneTimeKey,
        isFallback: false,
      );
      // Signed for bob, claimed for carol.
      expect(
        err(await alice.engine.createOutbound('carol', forged)),
        isA<DeviceKeysFailure>(),
      );
      expect(await alice.engine.hasSession('carol'), isFalse);
      expect(await alice.sessions(), isEmpty);
    });
  });

  test('createOutbound with no stored account is SessionStoreFailure, '
      'nothing stored', () async {
    await alice.exec("DELETE FROM meta WHERE key = 'olm_account'");
    expect(
      err(await alice.engine.createOutbound('bob', bob.keys())),
      isA<SessionStoreFailure>(),
    );
    expect(await alice.engine.hasSession('bob'), isFalse);
  });

  group('several sessions with one peer', () {
    test(
      'encrypt uses the newest-used session; decrypt tries older ones',
      () async {
        await established();
        final s1 = (await bob.sessions()).single['session_id'];
        // Alice locks one on S1, then opens S2.
        final onS1 = ok(await alice.engine.encrypt('bob', 'eski'));
        expect(onS1.sessionId, s1);
        final onS2 = await first('yeni');
        expect(onS2.sessionId, isNot(s1));

        expect(ok(await bobOpens(onS2)), 'yeni');
        expect(
          ok(await bob.engine.encrypt('alice', 'a')).sessionId,
          onS2.sessionId,
          reason: 'S2 is the newest used',
        );

        expect(ok(await bobOpens(onS1)), 'eski', reason: 'older session tried');
        expect(
          ok(await bob.engine.encrypt('alice', 'b')).sessionId,
          s1,
          reason: 'S1 now newest used (lastUsedAt saved on decrypt)',
        );
      },
    );
  });

  group('one transaction', () {
    test('plaintext goes to the stored row (body and search) with the '
        'session', () async {
      await bob.placeholder('m1');
      final m = await first('kahvaltı hazır');
      expect(
        ok(
          await bobOpens(m, save: const PlaintextSave('m1', 'kahvaltı hazır')),
        ),
        'kahvaltı hazır',
      );
      expect(await bob.body('m1'), 'kahvaltı hazır');
      expect(ids(await bob.store.search('kahvaltı')), ['m1']);
    });

    test('a save for a message not stored writes no row', () async {
      final m = await first();
      ok(await bobOpens(m, save: const PlaintextSave('nope', 'merhaba')));
      expect(await bob.body('nope'), isNull);
    });

    test('encrypt writes the sender copy in the same call', () async {
      await established();
      await alice.placeholder('s1', sender: 'alice');
      ok(
        await alice.engine.encrypt(
          'bob',
          'gönderdim',
          save: const PlaintextSave('s1', 'gönderdim'),
        ),
      );
      expect(await alice.body('s1'), 'gönderdim');
    });

    for (final (name, trigger) in [
      ('the plaintext row', 'BEFORE UPDATE ON messages'),
      ('the session row (insert)', 'BEFORE INSERT ON olm_sessions'),
      ('the account pickle', 'BEFORE UPDATE ON meta'),
    ]) {
      test('pre-key decrypt: a failure writing $name rolls back session, '
          'account and plaintext', () async {
        await bob.placeholder('m1');
        final m = await first('geri al');
        await bob.exec(
          'CREATE TRIGGER fail_tx $trigger BEGIN '
          "SELECT RAISE(ABORT, 'forced'); END",
        );
        // An upsert of meta may be INSERT OR REPLACE: block its insert too.
        if (trigger.contains('meta')) {
          await bob.exec(
            "CREATE TRIGGER fail_tx2 BEFORE INSERT ON meta BEGIN "
            "SELECT RAISE(ABORT, 'forced'); END",
          );
        }
        final before = await bob.snapshot();
        final r = await bobOpens(m, save: const PlaintextSave('m1', 'geri al'));
        expect(err(r), isA<Failure>());
        await bob.exec('DROP TRIGGER IF EXISTS fail_tx');
        await bob.exec('DROP TRIGGER IF EXISTS fail_tx2');
        expect(await bob.snapshot(), before, reason: 'partial write kept');
        expect(await bob.engine.hasSession('alice'), isFalse);
        // The one-time key is still in the stored account: the retry opens it.
        expect(
          ok(await bobOpens(m, save: const PlaintextSave('m1', 'geri al'))),
          'geri al',
        );
        expect(await bob.body('m1'), 'geri al');
      });
    }

    for (final (name, trigger) in [
      ('the plaintext row', 'BEFORE UPDATE ON messages'),
      ('the session row', 'BEFORE UPDATE ON olm_sessions'),
    ]) {
      test('normal decrypt: a failure writing $name rolls back and the '
          'message still opens later', () async {
        await established();
        await bob.placeholder('m2');
        final m = ok(await alice.engine.encrypt('bob', 'tekrar'));
        await bob.exec(
          'CREATE TRIGGER fail_tx $trigger BEGIN '
          "SELECT RAISE(ABORT, 'forced'); END",
        );
        // A session save may be INSERT OR REPLACE: block its insert too.
        if (trigger.contains('olm_sessions')) {
          await bob.exec(
            'CREATE TRIGGER fail_tx2 BEFORE INSERT ON olm_sessions BEGIN '
            "SELECT RAISE(ABORT, 'forced'); END",
          );
        }
        final before = await bob.snapshot();
        expect(
          err(await bobOpens(m, save: const PlaintextSave('m2', 'tekrar'))),
          isA<Failure>(),
        );
        await bob.exec('DROP TRIGGER IF EXISTS fail_tx');
        await bob.exec('DROP TRIGGER IF EXISTS fail_tx2');
        expect(await bob.snapshot(), before, reason: 'partial write kept');
        expect(
          ok(await bobOpens(m, save: const PlaintextSave('m2', 'tekrar'))),
          'tekrar',
          reason: 'stored session advanced although the call failed',
        );
      });
    }

    test('encrypt: a failure writing the sender copy rolls back the session '
        'pickle', () async {
      await established();
      await alice.placeholder('s1');
      await alice.exec(
        'CREATE TRIGGER fail_tx BEFORE UPDATE ON messages BEGIN '
        "SELECT RAISE(ABORT, 'forced'); END",
      );
      final before = await alice.snapshot();
      expect(
        err(
          await alice.engine.encrypt(
            'bob',
            'x',
            save: const PlaintextSave('s1', 'x'),
          ),
        ),
        isA<Failure>(),
      );
      expect(await alice.snapshot(), before);
    });

    test('the account pickle changes only on createInbound or a pre-key '
        'decrypt that makes a session', () async {
      final a0 = await alice.accountPickle();
      final b0 = await bob.accountPickle();
      expect(a0, isNotNull);

      final m = await first();
      expect(await alice.accountPickle(), a0, reason: 'createOutbound/encrypt');
      expect(await alice.engine.hasSession('bob'), isTrue);

      ok(await bobOpens(m));
      final b1 = await bob.accountPickle();
      expect(b1, isNot(b0), reason: 'one-time key consumed but not saved');

      final again = ok(await alice.engine.encrypt('bob', 'iki'));
      expect(again.olmType, 0);
      ok(await bobOpens(again));
      expect(await bob.accountPickle(), b1, reason: 'no new key consumed');

      final reply = ok(await bob.engine.encrypt('alice', 'r'));
      ok(await aliceOpens(reply));
      expect(await bob.accountPickle(), b1, reason: 'encrypt');
      expect(await alice.accountPickle(), a0, reason: 'normal decrypt');

      // createInbound directly, on a second session from Carol.
      final carol = await Phone.make('carol');
      ok(await carol.engine.createOutbound('bob', bob.keys()));
      final c = ok(await carol.engine.encrypt('bob', 'c'));
      ok(
        await bob.engine.createInbound(
          peerUserId: 'carol',
          peerIdentityKey: carol.identityKey,
          ciphertext: c.ciphertext,
          olmType: 0,
        ),
      );
      expect(await bob.accountPickle(), isNot(b1), reason: 'createInbound');
    });
  });
}

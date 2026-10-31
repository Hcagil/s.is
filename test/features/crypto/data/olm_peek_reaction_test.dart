// peekReaction against a REAL SQLite3 Multiple Ciphers store written by the
// production store (DriftMessageStore, DriftSessionEngine over REAL Olm,
// DriftChatListSnapshotStore). Written from the reaction peek contract
// (design t_a337e6d066 A4 P1-P7, AC-11/12/14), never from the code.
//
// Alice owns the phone and the reacted message; Bob is her 1:1 peer and the
// reactor. Bob's phone locks the reaction envelope with his real Olm session.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart' show MessageDeletion;
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/reaction_envelope.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/olm_peek.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';
import 'package:sis/features/notifications/data/push_peek_entry.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../chat/data/store/store_harness.dart';

const aliceId = '0a11ce00-0000-4000-8000-00000000a11c';
const bobId = '0b0b0000-0000-4000-8000-000000000b0b';
const carolId = '0ca401a0-0000-4000-8000-0000000ca401';
const conv = 'c0c0c0c0-0000-4000-8000-0000000c0c01';
const mine = 'aaaa0001-0000-4000-8000-00000000aaaa';
const thumb = '👍';

final class _FixedPickleKey implements PickleKeyStore {
  _FixedPickleKey(this.key);
  final List<int> key;
  @override
  Future<List<int>> loadOrCreate() async => key;
  @override
  Future<void> delete() async {}
}

/// One phone: its own real store file, Olm account, pickle key and engine.
final class Phone {
  Phone(this.userId, this.h, this.keyHex, this.store, this.engine, this.pk);
  final String userId;
  final StoreHarness h;
  final String keyHex;
  DriftMessageStore store;
  DriftSessionEngine engine;
  final List<int> pk;
  late final OlmKeyEngine olm;
  late final String identityKey;
  late final ClaimedKeys Function() keys;

  void reopen() {
    store = h.open(owner: userId, key: keyHex);
    addTearDown(store.close);
    engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: _FixedPickleKey(pk),
      now: () => DateTime.utc(2026, 4, 1),
    );
  }

  static Future<Phone> make(String userId) async {
    final h = await StoreHarness.create();
    final keyHex = await h.newKey();
    final store = h.open(owner: userId, key: keyHex);
    addTearDown(store.close);
    final olm = OlmKeyEngine();
    final pk = List<int>.generate(32, (i) => (i * 7 + userId.length) % 256);
    final account = await olm.create();
    account.generateOneTimeKeys(5);
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
    final p = Phone(userId, h, keyHex, store, engine, pk);
    p.identityKey = account.identityKey;
    p.olm = olm;
    var next = 0;
    p.keys = () => ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: account.sign(
        deviceStatement(userId, account.identityKey, account.signingKey),
      ),
      oneTimeKey: otks[next++],
      isFallback: false,
    );
    return p;
  }
}

T ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok, got $r');
  return (r as Ok<T>).value;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Phone alice;
  late Phone bob;

  setUp(() async {
    alice = await Phone.make(aliceId);
    bob = await Phone.make(bobId);
    // Alice's own copy of the chat: its peer is Bob, under the local name.
    await DriftChatListSnapshotStore(alice.store).save(aliceId, const [
      Conversation(
        id: conv,
        other: Member(userId: bobId, displayName: 'Bob Snapshot'),
      ),
    ]);
  });

  /// Bob locks a reaction envelope for Alice on his newest session.
  Future<LockedText> bobReacts({
    String messageId = mine,
    String envelopeUser = bobId,
    String? envelopeMessage,
    String emoji = thumb,
  }) async => ok(
    await bob.engine.encrypt(
      aliceId,
      encodeReactionEnvelope(
        messageId: envelopeMessage ?? messageId,
        userId: envelopeUser,
        emoji: emoji,
      ),
      peerIdentityKey: alice.identityKey,
    ),
  );

  /// Alice started the chat (her outbound session), Bob opened her first
  /// message: Bob's next lock is type 1, Alice holds the session.
  Future<void> sessionsBothWays() async {
    ok(await alice.engine.createOutbound(bobId, bob.keys()));
    final first = ok(
      await alice.engine.encrypt(
        bobId,
        encodeEnvelope(id: 'w1', text: 'first'),
        peerIdentityKey: bob.identityKey,
      ),
    );
    ok(
      await bob.engine.decrypt(
        peerUserId: aliceId,
        peerIdentityKey: alice.identityKey,
        ciphertext: first.ciphertext,
        olmType: first.olmType,
      ),
    );
  }

  Future<void> storeOnAlice(
    String body, {
    String id = mine,
    String sender = aliceId,
    MessageDeletion? deletion,
  }) => alice.store.upsertAll([
    msg(id, conv: conv, sender: sender, body: body, deletion: deletion),
  ]);

  Future<PeekedReaction?> peek(
    LockedText m, {
    String messageId = mine,
    String reactor = bobId,
    String owner = aliceId,
    String? keyHex,
    List<String>? reasons,
    List<String>? names,
  }) => peekReaction(
    storePath: alice.h.file.path,
    storeKeyHex: keyHex ?? alice.keyHex,
    pickleKey: alice.pk,
    ownerId: owner,
    conversationId: conv,
    messageId: messageId,
    reactorId: reactor,
    ciphertext: m.ciphertext,
    olmType: m.olmType,
    onFail: reasons?.add,
    onPeerName: names?.add,
  );

  /// olm_sessions + the account (meta) as one comparable value.
  String crypto() {
    final db = sqlite3.open(alice.h.file.path);
    try {
      db.execute("PRAGMA key = \"x'${alice.keyHex}'\";");
      return [
        for (final r in db.select('SELECT * FROM olm_sessions ORDER BY 1'))
          r.values,
        for (final r in db.select('SELECT key, value FROM meta ORDER BY 1'))
          r.values,
      ].toString();
    } finally {
      db.close();
    }
  }

  int count(String table) {
    final db = sqlite3.open(alice.h.file.path);
    try {
      db.execute("PRAGMA key = \"x'${alice.keyHex}'\";");
      return db.select('SELECT count(*) AS n FROM $table').first['n'] as int;
    } finally {
      db.close();
    }
  }

  group('AC-11 opened with a stored session', () {
    test('my own stored message: the real emoji and its quote', () async {
      await sessionsBothWays();
      await storeOnAlice('See you at 6');
      final r = await bobReacts();
      expect(r.olmType, 1, reason: 'fixture: an established session');
      await alice.store.close();
      final got = await peek(r);
      expect(got?.emoji, thumb);
      expect(got?.quote, 'See you at 6');
    });

    test('the reacted message is not in the store: emoji, no quote', () async {
      await sessionsBothWays();
      final r = await bobReacts();
      await alice.store.close();
      final got = await peek(r);
      expect(got?.emoji, thumb);
      expect(got?.quote, isNull);
    });

    test('a pre-key reaction on a session Alice already stores is opened '
        '(P3: by the stored session id)', () async {
      // Bob started this chat: Alice stored his session from his first
      // message, and Bob has had no answer, so his reaction is still type 0.
      ok(await bob.engine.createOutbound(aliceId, alice.keys()));
      final first = ok(
        await bob.engine.encrypt(
          aliceId,
          encodeEnvelope(id: 'w1', text: 'hello'),
          peerIdentityKey: alice.identityKey,
        ),
      );
      ok(
        await alice.engine.decrypt(
          peerUserId: bobId,
          peerIdentityKey: bob.identityKey,
          ciphertext: first.ciphertext,
          olmType: first.olmType,
        ),
      );
      final r = await bobReacts();
      expect(r.olmType, 0, reason: 'fixture: still a pre-key message');
      await alice.store.close();
      expect((await peek(r))?.emoji, thumb);
    });
  });

  group('P5 the quote', () {
    Future<String?> quoteOf(
      String body, {
      String sender = aliceId,
      MessageDeletion? deletion,
    }) async {
      await sessionsBothWays();
      await storeOnAlice(body, sender: sender, deletion: deletion);
      final r = await bobReacts();
      await alice.store.close();
      final got = await peek(r);
      expect(got?.emoji, thumb, reason: 'the emoji is shown either way');
      return got?.quote;
    }

    test('not my message (the peer sent it): no quote', () async {
      expect(await quoteOf('his words', sender: bobId), isNull);
    });

    test('a deleted message: no quote', () async {
      expect(
        await quoteOf('gone words', deletion: MessageDeletion.vanished),
        isNull,
      );
    });

    test('the locked placeholder: no quote', () async {
      expect(await quoteOf(lockedBodyPlaceholder), isNull);
    });

    test('a blank body: no quote', () async {
      expect(await quoteOf('   '), isNull);
    });

    test('exactly 60 characters: kept whole', () async {
      final s = 'a' * 60;
      expect(await quoteOf(s), s);
    });

    test('61 characters: the first 60 plus an ellipsis', () async {
      expect(await quoteOf('${'b' * 60}c'), '${'b' * 60}…');
    });

    test(
      'the cut counts characters, never splits one (family emoji)',
      () async {
        const family = '👨‍👩‍👧';
        expect(await quoteOf(family * 61), '${family * 60}…');
      },
    );
  });

  group('AC-11 not opened: null (generic text)', () {
    test('no session at all', () async {
      // Bob made a session from Alice's published keys; Alice never stored it.
      ok(await bob.engine.createOutbound(aliceId, alice.keys()));
      final r = await bobReacts();
      expect(r.olmType, 0);
      await alice.store.close();
      final reasons = <String>[];
      expect(await peek(r, reasons: reasons), isNull);
      expect(reasons, hasLength(1));
      expect(reasons.single, isIn(['no_session', 'decrypt_fail']));
    });

    test('a pre-key reaction on a brand-new session is not opened, even with '
        'an older stored session (P3: no first-contact peek)', () async {
      await sessionsBothWays();
      ok(await bob.engine.createOutbound(aliceId, alice.keys()));
      final r = await bobReacts();
      expect(r.olmType, 0, reason: 'fixture: a new pre-key session');
      await alice.store.close();
      final before = crypto();
      expect(await peek(r), isNull);
      expect(crypto(), before);
      // The app itself can still open it (the one-time key was not used).
      alice.reopen();
      final plain = ok(
        await alice.engine.decrypt(
          peerUserId: bobId,
          peerIdentityKey: bob.identityKey,
          ciphertext: r.ciphertext,
          olmType: r.olmType,
        ),
      );
      expect(plain, contains(thumb));
    });

    test('reactor_id is not the chat peer (P2)', () async {
      await sessionsBothWays();
      final r = await bobReacts();
      await alice.store.close();
      final reasons = <String>[];
      expect(await peek(r, reactor: carolId, reasons: reasons), isNull);
      expect(reasons, ['no_peer']);
    });

    test('the envelope names another reactor (u mismatch, P4)', () async {
      await sessionsBothWays();
      final r = await bobReacts(envelopeUser: carolId);
      await alice.store.close();
      final reasons = <String>[];
      expect(await peek(r, reasons: reasons), isNull);
      expect(reasons, ['decrypt_fail']);
    });

    test('the envelope is for another message (i mismatch, P4)', () async {
      await sessionsBothWays();
      final r = await bobReacts(
        envelopeMessage: 'bbbb0002-0000-4000-8000-00000000bbbb',
      );
      await alice.store.close();
      final reasons = <String>[];
      expect(await peek(r, reasons: reasons), isNull);
      expect(reasons, ['decrypt_fail']);
    });

    test('a message envelope (not a reaction) is refused', () async {
      await sessionsBothWays();
      final r = ok(
        await bob.engine.encrypt(
          aliceId,
          encodeEnvelope(id: mine, text: thumb),
          peerIdentityKey: alice.identityKey,
        ),
      );
      await alice.store.close();
      expect(await peek(r), isNull);
    });

    test('the push names another owner (P1)', () async {
      await sessionsBothWays();
      await storeOnAlice('See you at 6');
      final r = await bobReacts();
      await alice.store.close();
      final reasons = <String>[];
      expect(await peek(r, owner: carolId, reasons: reasons), isNull);
      expect(reasons, ['owner_mismatch']);
    });

    test('the store cannot be read (wrong key): rows_null', () async {
      await sessionsBothWays();
      final r = await bobReacts();
      await alice.store.close();
      final reasons = <String>[];
      expect(await peek(r, keyHex: 'ab' * 32, reasons: reasons), isNull);
      expect(reasons, ['rows_null']);
    });
  });

  group('AC-12 writes nothing', () {
    test('after a peek the store file is byte-for-byte unchanged, no '
        'push_inbox or reaction_plains row, and the app still opens the '
        'reaction', () async {
      await sessionsBothWays();
      await storeOnAlice('See you at 6');
      final r = await bobReacts();
      await alice.store.close();
      final bytes = await alice.h.file.readAsBytes();
      final keys = crypto();

      expect((await peek(r))?.emoji, thumb);
      expect((await peek(r))?.emoji, thumb, reason: 'nothing consumed');

      expect(crypto(), keys, reason: 'olm_sessions and meta unchanged');
      expect(await alice.h.file.readAsBytes(), bytes);
      expect(count('push_inbox'), 0);
      expect(count('reaction_plains'), 0);
      alice.reopen();
      final plain = ok(
        await alice.engine.decrypt(
          peerUserId: bobId,
          peerIdentityKey: bob.identityKey,
          ciphertext: r.ciphertext,
          olmType: r.olmType,
        ),
      );
      expect(plain, contains(thumb));
    });
  });

  group('AC-14 the name', () {
    test(
      'onPeerName gets the name from the phone\'s own copy of the chat',
      () async {
        await sessionsBothWays();
        final r = await bobReacts();
        await alice.store.close();
        final names = <String>[];
        expect((await peek(r, names: names))?.emoji, thumb);
        expect(names, ['Bob Snapshot']);
      },
    );
  });

  // A3: the seam to Kotlin. PeekRunner answers 'take' with the push fields
  // (now with kind and reactor_id); peekMain answers 'done' with emoji, quote
  // and the local name, and text null. The keys come from the real
  // secure-storage names, the file from the app support directory.
  group('A3 peekMain for a reaction', () {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

    Future<Map<Object?, Object?>> runPeekMain(
      Map<String, String> take, {
      Phone? phone,
    }) async {
      final ph = phone ?? alice;
      String hex(List<int> b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      FlutterSecureStorage.setMockInitialValues({
        'sis.store.key': ph.keyHex,
        'sis.olm.pickle.key': hex(ph.pk),
      });
      final m =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(pathChannel, (c) async => ph.h.dir.path);
      Map<Object?, Object?>? done;
      m.setMockMethodCallHandler(peekChannel, (c) async {
        if (c.method == 'take') return take;
        if (c.method == 'done') done = c.arguments as Map<Object?, Object?>;
        return null;
      });
      addTearDown(() {
        m.setMockMethodCallHandler(pathChannel, null);
        m.setMockMethodCallHandler(peekChannel, null);
      });
      await peekMain();
      expect(done, isNotNull, reason: "'done' always answered");
      return done!;
    }

    Map<String, String> take(LockedText r, {String reactor = bobId}) => {
      'user_id': aliceId,
      'conversation_id': conv,
      'message_id': mine,
      'kind': 'reaction',
      'reactor_id': reactor,
      'ct': r.ciphertext,
      'ot': '${r.olmType}',
      'budget_ms': '3000',
    };

    test("'take' with kind reaction: 'done' carries emoji, quote and the "
        'local name, no text, and nothing is written', () async {
      await sessionsBothWays();
      await storeOnAlice('See you at 6');
      final r = await bobReacts();
      await alice.store.close();
      final bytes = await alice.h.file.readAsBytes();
      final done = await runPeekMain(take(r));
      expect(done['emoji'], thumb);
      expect(done['quote'], 'See you at 6');
      expect(done['name'], 'Bob Snapshot');
      expect(done['text'], isNull);
      expect(await alice.h.file.readAsBytes(), bytes);
      expect(count('push_inbox'), 0);
    });

    test("'take' with a reactor_id that is not a UUID: no emoji", () async {
      await sessionsBothWays();
      final r = await bobReacts();
      await alice.store.close();
      final done = await runPeekMain(take(r, reactor: 'not-a-uuid'));
      expect(done['emoji'], isNull);
      expect(done['quote'], isNull);
      expect(done['reason'], isNotNull);
    });

    test('a reactor id that is not UUID-shaped is refused even when the '
        'local peer, the session and the envelope all name it', () async {
      const odd = 'bob';
      final a = await Phone.make(aliceId);
      final b = await Phone.make(odd);
      await DriftChatListSnapshotStore(a.store).save(aliceId, const [
        Conversation(
          id: conv,
          other: Member(userId: odd, displayName: 'Bob Snapshot'),
        ),
      ]);
      ok(await a.engine.createOutbound(odd, b.keys()));
      final first = ok(
        await a.engine.encrypt(
          odd,
          encodeEnvelope(id: 'w1', text: 'first'),
          peerIdentityKey: b.identityKey,
        ),
      );
      ok(
        await b.engine.decrypt(
          peerUserId: aliceId,
          peerIdentityKey: a.identityKey,
          ciphertext: first.ciphertext,
          olmType: first.olmType,
        ),
      );
      final r = ok(
        await b.engine.encrypt(
          aliceId,
          encodeReactionEnvelope(messageId: mine, userId: odd, emoji: thumb),
          peerIdentityKey: a.identityKey,
        ),
      );
      await a.store.close();
      final done = await runPeekMain({
        'user_id': aliceId,
        'conversation_id': conv,
        'message_id': mine,
        'kind': 'reaction',
        'reactor_id': odd,
        'ct': r.ciphertext,
        'ot': '${r.olmType}',
      }, phone: a);
      expect(done['emoji'], isNull);
      expect(done['reason'], isNotNull);
    });
  });
}

// peekEncryptedText / readPeekRows against a REAL SQLite3 Multiple Ciphers
// store file written by the production store (DriftMessageStore,
// DriftSessionEngine over REAL Olm, DriftChatListSnapshotStore). Written from
// the peek contract (QA interface of Private Chats 4b Group G), never from the
// implementation: the file is opened read-only, nothing is ever written, any
// failure is null, and a held lock gives null after about 1 s, never a hang.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/message.dart' show MessageDeletion;
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/push_inbox_store.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/data/olm_peek.dart';
import 'package:sis/features/crypto/data/olm_peek_store.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../chat/data/store/store_harness.dart';

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

  /// After a close: the app opens the same file again (new store, engine).
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

  late final String identityKey;
  late final ClaimedKeys Function() keys;

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
    alice = await Phone.make('alice');
    bob = await Phone.make('bob');
    await DriftChatListSnapshotStore(bob.store).save('bob', const [
      Conversation(
        id: 'c1',
        other: Member(userId: 'alice', displayName: 'Alice'),
      ),
      Conversation(
        id: 'c2',
        other: Member(userId: 'carol', displayName: 'Carol'),
      ),
    ]);
  });

  Future<LockedText> aliceSends(String id, String text) async => ok(
    await alice.engine.encrypt(
      'bob',
      encodeEnvelope(id: id, text: text),
      peerIdentityKey: bob.identityKey,
    ),
  );

  Future<Result<String>> bobOpens(LockedText m) => bob.engine.decrypt(
    peerUserId: 'alice',
    peerIdentityKey: alice.identityKey,
    ciphertext: m.ciphertext,
    olmType: m.olmType,
  );

  /// Sessions both ways; returns a type 1 message m2 not yet opened by Bob,
  /// stored on his phone as the placeholder row (as the sync writes it).
  Future<LockedText> normalMessage({String conv = 'c1'}) async {
    ok(await alice.engine.createOutbound('bob', bob.keys()));
    ok(await bobOpens(await aliceSends('m1', 'first')));
    final reply = ok(
      await bob.engine.encrypt(
        'alice',
        encodeEnvelope(id: 'r1', text: 'reply'),
        peerIdentityKey: alice.identityKey,
      ),
    );
    ok(
      await alice.engine.decrypt(
        peerUserId: 'bob',
        peerIdentityKey: bob.identityKey,
        ciphertext: reply.ciphertext,
        olmType: reply.olmType,
      ),
    );
    final m2 = await aliceSends('m2', 'secret words');
    expect(m2.olmType, 1);
    await bob.store.upsertAll([
      msg('m2', conv: conv, sender: 'alice', body: lockedBodyPlaceholder),
    ]);
    return m2;
  }

  Future<String?> peek(
    LockedText m, {
    String id = 'm2',
    String owner = 'bob',
    String conv = 'c1',
    String? keyHex,
    String? path,
  }) => peekEncryptedText(
    storePath: path ?? bob.h.file.path,
    storeKeyHex: keyHex ?? bob.keyHex,
    pickleKey: bob.pk,
    ownerId: owner,
    conversationId: conv,
    messageId: id,
    ciphertext: m.ciphertext,
    olmType: m.olmType,
  );

  test('readPeekRows reads owner, peer, placeholder, account and the '
      "peer's sessions", () async {
    await normalMessage();
    await bob.store.close();
    final r = readPeekRows(
      path: bob.h.file.path,
      keyHex: bob.keyHex,
      conversationId: 'c1',
      messageId: 'm2',
    );
    expect(r, isNotNull);
    expect(r!.ownerId, 'bob');
    expect(r.peerUserId, 'alice');
    expect(r.storedBody, lockedBodyPlaceholder);
    expect(r.account, isNotNull);
    expect(r.sessions, isNotEmpty);
    expect(r.sessions.every((s) => s.peerUserId == 'alice'), isTrue);
    expect(r.sessions.first.peerIdentityKey, alice.identityKey);
  });

  // Audit L3 (t_a9ef0f411f Fix 3): the name a notification shows comes from
  // the phone's own copy of the chat (json other.name), not from the push.
  group('peer name from the phone\'s own copy', () {
    test('readPeekRows.peerName is the chat partner of that chat', () async {
      await normalMessage();
      await bob.store.close();
      PeekRows? rows(String conv) => readPeekRows(
        path: bob.h.file.path,
        keyHex: bob.keyHex,
        conversationId: conv,
        messageId: 'm2',
      );
      expect(rows('c1')?.peerName, 'Alice');
      expect(rows('c2')?.peerName, 'Carol');
      expect(rows('c9')?.peerName, isNull);
    });

    test('an empty name in the copy is null', () async {
      await DriftChatListSnapshotStore(bob.store).save('bob', const [
        Conversation(
          id: 'c1',
          other: Member(userId: 'alice', displayName: ''),
        ),
      ]);
      await normalMessage();
      await bob.store.close();
      final r = readPeekRows(
        path: bob.h.file.path,
        keyHex: bob.keyHex,
        conversationId: 'c1',
        messageId: 'm2',
      );
      expect(r?.peerUserId, 'alice');
      expect(r?.peerName, isNull);
    });

    test(
      'peekEncryptedText hands that name to onPeerName with the text',
      () async {
        final m2 = await normalMessage();
        final names = <String>[];
        final text = await peekEncryptedText(
          storePath: bob.h.file.path,
          storeKeyHex: bob.keyHex,
          pickleKey: bob.pk,
          ownerId: 'bob',
          conversationId: 'c1',
          messageId: 'm2',
          ciphertext: m2.ciphertext,
          olmType: m2.olmType,
          onPeerName: names.add,
        );
        expect(text, 'secret words');
        expect(names, ['Alice']);
      },
    );
  });

  test('a placeholder row is peeked: the text comes back, the store file '
      'is byte-for-byte unchanged, and the real decrypt still works', () async {
    final m2 = await normalMessage();
    await bob.store.close();
    final before = await bob.h.file.readAsBytes();
    final mtime = await bob.h.file.lastModified();

    expect(await peek(m2), 'secret words');
    expect(await peek(m2), 'secret words');

    expect(await bob.h.file.readAsBytes(), before);
    expect(await bob.h.file.lastModified(), mtime);
    // Nothing advanced: the app itself can still open the message.
    bob.reopen();
    expect(ok(await bobOpens(m2)), contains('secret words'));
  });

  test('a pre-key message on a new session peeks without consuming the '
      'one-time key (the app can still open it afterwards)', () async {
    ok(await alice.engine.createOutbound('bob', bob.keys()));
    ok(await bobOpens(await aliceSends('m1', 'first')));
    // Alice starts over with a new session (new one-time key): type 0.
    ok(await alice.engine.createOutbound('bob', bob.keys()));
    final m3 = await aliceSends('m3', 'fresh start');
    expect(m3.olmType, 0);
    await bob.store.upsertAll([
      msg('m3', sender: 'alice', body: lockedBodyPlaceholder),
    ]);
    await bob.store.close();
    final before = await bob.h.file.readAsBytes();

    expect(await peek(m3, id: 'm3'), 'fresh start');

    expect(await bob.h.file.readAsBytes(), before);
    bob.reopen();
    expect(ok(await bobOpens(m3)), contains('fresh start'));
  });

  test('a stored real body is returned without Olm', () async {
    await bob.store.upsertAll([
      msg('m9', sender: 'alice', body: 'already opened text'),
    ]);
    await bob.store.close();
    // Ciphertext and type are garbage: Olm cannot have produced this.
    final junk = const LockedText(ciphertext: '!!', olmType: 7, sessionId: 'x');
    expect(await peek(junk, id: 'm9'), 'already opened text');
  });

  test('a stored body is only taken from the same conversation', () async {
    await bob.store.upsertAll([
      msg('m9', conv: 'c2', sender: 'carol', body: 'text from chat B'),
    ]);
    await bob.store.close();
    final junk = const LockedText(ciphertext: '!!', olmType: 1, sessionId: 'x');
    expect(await peek(junk, id: 'm9', conv: 'c1'), isNull);
    // Same id, its own conversation: the stored text comes back.
    expect(await peek(junk, id: 'm9', conv: 'c2'), 'text from chat B');
  });

  // t_5d6bdca09e: the stored text is reused only when its row's sender is the
  // chat's peer; the reader hands that sender over as storedSenderId.
  group('stored text and its sender', () {
    const junk = LockedText(ciphertext: '!!', olmType: 1, sessionId: 'x');

    PeekRows? read(String id, {String conv = 'c1'}) => readPeekRows(
      path: bob.h.file.path,
      keyHex: bob.keyHex,
      conversationId: conv,
      messageId: id,
    );

    test('readPeekRows.storedSenderId is the sender of that row, null '
        'without a row', () async {
      await bob.store.upsertAll([
        msg('m9', sender: 'alice', body: 'from alice'),
        msg('m8', sender: 'bob', body: 'from me'),
        msg(
          'm7',
          sender: 'alice',
          body: 'gone',
          deletion: MessageDeletion.placeholder,
        ),
      ]);
      await bob.store.close();
      expect(read('m9')?.storedSenderId, 'alice');
      expect(read('m8')?.storedSenderId, 'bob');
      expect(read('none')?.storedSenderId, isNull);
      expect(read('m7')?.storedSenderId, isNull, reason: 'a deleted row');
    });

    for (final sender in ['bob', 'carol']) {
      test('a stored text whose row sender is $sender (not the peer alice) '
          'is never shown', () async {
        await bob.store.upsertAll([
          msg('m9', sender: sender, body: 'forged text'),
        ]);
        await bob.store.close();
        expect(await peek(junk, id: 'm9'), isNull);
      });
    }

    test('a chat not in the snapshot (unknown peer): a stored text is never '
        'shown', () async {
      await bob.store.upsertAll([
        msg('m9', conv: 'c9', sender: 'dave', body: 'unknown chat text'),
      ]);
      await bob.store.close();
      expect(await peek(junk, id: 'm9', conv: 'c9'), isNull);
    });

    test('a deleted row in a chat not in the snapshot (no sender, no peer) '
        'is never shown', () async {
      await bob.store.upsertAll([
        msg(
          'm9',
          conv: 'c9',
          sender: 'dave',
          body: 'deleted text',
          deletion: MessageDeletion.placeholder,
        ),
      ]);
      await bob.store.close();
      expect(await peek(junk, id: 'm9', conv: 'c9'), isNull);
    });

    test('a row stored as sent by me falls through to Olm: the real text, '
        'not the stored one', () async {
      final m2 = await normalMessage();
      await bob.store.upsertAll([
        msg('m2', sender: 'bob', body: 'forged text'),
      ]);
      await bob.store.close();
      expect(await peek(m2), 'secret words');
    });
  });

  test(
    'the conversation peer differs from the session owner => null',
    () async {
      final m2 = await normalMessage(conv: 'c2');
      await bob.store.close();
      expect(await peek(m2, conv: 'c2'), isNull);
    },
  );

  test('wrong ownerId => null', () async {
    final m2 = await normalMessage();
    await bob.store.close();
    expect(await peek(m2, owner: 'mallory'), isNull);
  });

  test('wrong store key => null, file unchanged', () async {
    final m2 = await normalMessage();
    await bob.store.close();
    final before = await bob.h.file.readAsBytes();
    FlutterSecureStorage.setMockInitialValues({});
    final other = await const StoreKey().loadOrCreate();
    expect(other, isNot(bob.keyHex));
    expect(await peek(m2, keyHex: other), isNull);
    expect(await bob.h.file.readAsBytes(), before);
  });

  test('missing file => null and no file is created', () async {
    final m2 = await normalMessage();
    final missing = '${bob.h.dir.path}/nope.sqlite';
    expect(await peek(m2, path: missing), isNull);
    expect(File(missing).existsSync(), isFalse);
  });

  test('a file held by a writer => null, never hangs', () async {
    final m2 = await normalMessage();
    await bob.store.close();
    final writer = sqlite3.open(bob.h.file.path);
    addTearDown(writer.close);
    writer.execute("PRAGMA key = \"x'${bob.keyHex}'\";");
    writer.execute('BEGIN EXCLUSIVE;');
    writer.execute("UPDATE meta SET value = value WHERE key = 'owner_id';");

    final sw = Stopwatch()..start();
    final text = await peek(m2).timeout(const Duration(seconds: 10));
    sw.stop();
    writer.execute('ROLLBACK;');

    expect(text, isNull);
    // Held past the ~1 s busy wait: the peek retried for about 1 s, then gave up.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(800));
    expect(sw.elapsedMilliseconds, lessThan(4000));
    // Lock released: the peek works again.
    expect(await peek(m2), 'secret words');
  });

  test('a writer that holds the lock for 300 ms is waited for (busy '
      'timeout about 1 s): the peek still returns the text', () async {
    final m2 = await normalMessage();
    await bob.store.close();
    final locked = ReceivePort();
    await Isolate.spawn(_holdLock, [
      bob.h.file.path,
      bob.keyHex,
      locked.sendPort,
    ]);
    final events = StreamIterator(locked);
    expect(await events.moveNext(), isTrue); // lock taken
    final sw = Stopwatch()..start();
    final text = await peek(m2);
    sw.stop();
    expect(await events.moveNext(), isTrue); // lock released
    locked.close();
    expect(text, 'secret words');
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
  });

  // Slice 2 (t_428ad7c883): with budgetLeftMs the peek also saves the opened
  // text into push_inbox, only when a STORED session or peer key opened it
  // (W1), the chat is in the store (W2), with the store's peer as sender (W3)
  // and sealed = sha256 hex of the ciphertext string. The ratchet is never
  // saved: the app opens the same ciphertext afterwards.
  group('push_inbox write (Android)', () {
    List<Map<String, Object?>> inboxRows(Phone p) {
      final db = sqlite3.open(p.h.file.path);
      try {
        db.execute("PRAGMA key = \"x'${p.keyHex}'\";");
        return [
          for (final r in db.select('SELECT * FROM push_inbox')) {...r},
        ];
      } finally {
        db.close();
      }
    }

    Future<String?> peekSave(
      LockedText m, {
      String id = 'm2',
      String conv = 'c1',
      int budget = 3000,
      String? si,
      List<String>? codes,
    }) => peekEncryptedText(
      storePath: bob.h.file.path,
      storeKeyHex: bob.keyHex,
      pickleKey: bob.pk,
      ownerId: 'bob',
      conversationId: conv,
      messageId: id,
      ciphertext: m.ciphertext,
      olmType: m.olmType,
      senderId: si,
      budgetLeftMs: () => budget,
      onInbox: codes?.add,
    );

    /// normalMessage, but the push came before any sync: no messages row.
    Future<LockedText> pushedFirst({String conv = 'c1'}) async {
      final m2 = await normalMessage(conv: conv);
      await bob.store.remove('m2');
      await bob.store.close();
      return m2;
    }

    test('a normal message (type 1) on a stored session is saved with the '
        'store peer as sender and sealed = sha256 of the ciphertext; the app '
        'opens the same ciphertext afterwards and its row replaces the '
        'inbox row', () async {
      final m2 = await pushedFirst();
      final codes = <String>[];
      expect(await peekSave(m2, codes: codes), 'secret words');
      expect(codes, ['saved']);
      final row = inboxRows(bob).single;
      expect(row['message_id'], 'm2');
      expect(row['conversation_id'], 'c1');
      expect(row['sender_id'], 'alice');
      expect(row['body'], 'secret words', reason: 'envelope text only');
      expect(
        row['sealed'],
        sha256.convert(utf8.encode(m2.ciphertext)).toString(),
      );

      bob.reopen();
      expect(ok(await bobOpens(m2)), contains('secret words'));
      await bob.store.upsertAll([
        msg('m2', sender: 'alice', body: 'secret words'),
      ]);
      expect(await (bob.store as PushInboxStore).pushInbox(), isEmpty);
    });

    test('a pre-key message on a new session with the stored peer key is '
        'saved; the one-time key is used up only by the app', () async {
      ok(await alice.engine.createOutbound('bob', bob.keys()));
      ok(await bobOpens(await aliceSends('m1', 'first')));
      ok(await alice.engine.createOutbound('bob', bob.keys()));
      final m3 = await aliceSends('m3', 'fresh start');
      expect(m3.olmType, 0);
      await bob.store.close();
      final codes = <String>[];
      expect(await peekSave(m3, id: 'm3', codes: codes), 'fresh start');
      expect(codes, ['saved']);
      expect(inboxRows(bob).single['sender_id'], 'alice');
      bob.reopen();
      expect(ok(await bobOpens(m3)), contains('fresh start'));
    });

    test('without budgetLeftMs nothing is written (file byte-for-byte '
        'unchanged)', () async {
      final m2 = await pushedFirst();
      final before = await bob.h.file.readAsBytes();
      final codes = <String>[];
      expect(
        await peekEncryptedText(
          storePath: bob.h.file.path,
          storeKeyHex: bob.keyHex,
          pickleKey: bob.pk,
          ownerId: 'bob',
          conversationId: 'c1',
          messageId: 'm2',
          ciphertext: m2.ciphertext,
          olmType: m2.olmType,
          onInbox: codes.add,
        ),
        'secret words',
      );
      expect(codes, isEmpty, reason: 'no write attempted');
      expect(inboxRows(bob), isEmpty);
      expect(await bob.h.file.readAsBytes(), before);
    });

    test('budgetLeftMs given and no onInbox listener: the text is still '
        'saved (onInbox only reports the code)', () async {
      final m2 = await pushedFirst();
      expect(
        await peekEncryptedText(
          storePath: bob.h.file.path,
          storeKeyHex: bob.keyHex,
          pickleKey: bob.pk,
          ownerId: 'bob',
          conversationId: 'c1',
          messageId: 'm2',
          ciphertext: m2.ciphertext,
          olmType: m2.olmType,
          budgetLeftMs: () => 3000,
        ),
        'secret words',
      );
      expect(inboxRows(bob).map((r) => r['message_id']), ['m2']);
    });

    test('under 500 ms left: the text is still shown, inbox_budget, no '
        'row', () async {
      final m2 = await pushedFirst();
      final codes = <String>[];
      expect(await peekSave(m2, budget: 499, codes: codes), 'secret words');
      expect(codes, ['inbox_budget']);
      expect(inboxRows(bob), isEmpty);
    });

    test('the lock placeholder already stored (the app could not open it): '
        'the app\'s row wins, no inbox row', () async {
      final m2 = await normalMessage();
      await bob.store.close();
      final codes = <String>[];
      expect(await peekSave(m2, codes: codes), 'secret words');
      expect(codes, ['inbox_skip']);
      expect(inboxRows(bob), isEmpty);
    });

    test('a failed decrypt writes nothing', () async {
      final m2 = await pushedFirst();
      final bad = LockedText(
        ciphertext: m2.ciphertext.replaceRange(20, 24, 'AAAA'),
        olmType: 1,
        sessionId: m2.sessionId,
      );
      final codes = <String>[];
      expect(await peekSave(bad, codes: codes), isNull);
      expect(codes, isNot(contains('saved')));
      expect(inboxRows(bob), isEmpty);
    });

    test('W2: a chat whose peer is not in the store gives no row', () async {
      // c2 is carol's chat; the session is alice's: refused, nothing saved.
      final m2 = await pushedFirst(conv: 'c2');
      expect(await peekSave(m2, conv: 'c2'), isNull);
      expect(inboxRows(bob), isEmpty);
      // A conversation id not in the store at all.
      expect(await peekSave(m2, conv: 'c9'), isNull);
      expect(inboxRows(bob), isEmpty);
    });

    // Slice 1 Android WAL: the read-only peek and the push write on a WAL
    // file, with the app's connection open (-shm present) and cold (none).
    for (final appOpen in [true, false]) {
      test(
        'WAL store, app ${appOpen ? 'open (-shm present)' : 'closed (no '
                  '-shm)'}: readPeekRows and the peek work, the push row is saved',
        () async {
          final m2 = await pushedFirst();
          final raw = sqlite3.open(bob.h.file.path);
          raw.execute("PRAGMA key = \"x'${bob.keyHex}'\";");
          expect(
            raw.select('PRAGMA journal_mode = WAL').first.values.first,
            'wal',
          );
          raw.close();
          if (appOpen) {
            bob.reopen();
            await bob.store.upsertAll([msg('w0', sender: 'alice', t: -5)]);
            expect(bob.h.shm.existsSync(), isTrue, reason: 'fixture: -shm');
          } else {
            expect(bob.h.shm.existsSync(), isFalse, reason: 'fixture: no -shm');
          }
          final r = readPeekRows(
            path: bob.h.file.path,
            keyHex: bob.keyHex,
            conversationId: 'c1',
            messageId: 'm2',
          );
          expect(r?.peerUserId, 'alice');
          expect(r!.sessions, isNotEmpty);
          final codes = <String>[];
          expect(await peekSave(m2, codes: codes), 'secret words');
          expect(codes, ['saved']);
          expect(inboxRows(bob).single['message_id'], 'm2');
        },
      );
    }

    test('W3: a push sender id (si) that is not the stored peer never '
        'becomes the saved sender', () async {
      final m2 = await pushedFirst();
      await peekSave(m2, si: '0000a11c-0000-4000-8000-0000000000ee');
      for (final r in inboxRows(bob)) {
        expect(r['sender_id'], 'alice');
      }
    });
  });

  // The sender key of a pre-key push (fix C contract): sk/si open a first
  // message with no stored session, read-only; a stored session of si wins;
  // a key already stored for another person is refused. Ids are uuids here
  // (si must be one).
  group('pre-key push with sender key (sk) and sender id (si)', () {
    const aId = '0000a11c-0000-4000-8000-0000000000a1';
    const bId = '0000a11c-0000-4000-8000-0000000000b2';
    const cId = '0000a11c-0000-4000-8000-0000000000c3';
    late Phone a, b, c;

    setUp(() async {
      a = await Phone.make(aId);
      b = await Phone.make(bId);
      c = await Phone.make(cId);
      // k1: 1:1 with alice in the snapshot. k3: not in the snapshot.
      await DriftChatListSnapshotStore(b.store).save(bId, const [
        Conversation(
          id: 'k1',
          other: Member(userId: aId, displayName: 'Alice'),
        ),
      ]);
    });

    Future<LockedText> send(Phone from, String id, String text) async {
      ok(await from.engine.createOutbound(bId, b.keys()));
      final m = ok(
        await from.engine.encrypt(
          bId,
          encodeEnvelope(id: id, text: text),
          peerIdentityKey: b.identityKey,
        ),
      );
      expect(m.olmType, 0, reason: 'fixture: a pre-key message');
      return m;
    }

    Future<String?> peekK(
      LockedText m,
      String id, {
      String conv = 'k1',
      String? sk,
      String? si,
    }) => peekEncryptedText(
      storePath: b.h.file.path,
      storeKeyHex: b.keyHex,
      pickleKey: b.pk,
      ownerId: bId,
      conversationId: conv,
      messageId: id,
      ciphertext: m.ciphertext,
      olmType: m.olmType,
      senderKey: sk,
      senderId: si,
    );

    Future<void> placeholder(String id, {String conv = 'k1'}) =>
        b.store.upsertAll([
          msg(id, conv: conv, sender: aId, body: lockedBodyPlaceholder),
        ]);

    test('first message, no session on the phone: sk/si open it, the store '
        'file is byte-for-byte unchanged, and the app still opens it '
        '(one-time key not consumed)', () async {
      final m = await send(a, 'f1', 'first ever');
      await placeholder('f1');
      await b.store.close();
      final before = await b.h.file.readAsBytes();
      final mtime = await b.h.file.lastModified();

      expect(
        await peekK(m, 'f1'),
        isNull,
        reason: 'without sk/si it stays locked',
      );
      expect(await peekK(m, 'f1', sk: a.identityKey, si: aId), 'first ever');
      expect(await peekK(m, 'f1', sk: a.identityKey, si: aId), 'first ever');

      expect(await b.h.file.readAsBytes(), before);
      expect(await b.h.file.lastModified(), mtime);
      b.reopen();
      final opened = ok(
        await b.engine.decrypt(
          peerUserId: aId,
          peerIdentityKey: a.identityKey,
          ciphertext: m.ciphertext,
          olmType: m.olmType,
        ),
      );
      expect(opened, contains('first ever'));
    });

    test('a chat not in the snapshot: si is the peer for this peek', () async {
      final m = await send(a, 'f3', 'no snapshot');
      await placeholder('f3', conv: 'k3');
      await b.store.close();
      expect(
        await peekK(m, 'f3', conv: 'k3', sk: a.identityKey, si: aId),
        'no snapshot',
      );
    });

    test('a stored session of si wins over sk, also with no snapshot peer '
        '(sessions are looked up by si)', () async {
      // Bob opened alice's first message: a stored session with her key.
      final first = await send(a, 'o1', 'old phone');
      ok(
        await b.engine.decrypt(
          peerUserId: aId,
          peerIdentityKey: a.identityKey,
          ciphertext: first.ciphertext,
          olmType: first.olmType,
        ),
      );
      // Alice's new phone: same user id, a new identity key.
      final a2 = await Phone.make(aId);
      final m = await send(a2, 'n1', 'new phone');
      await placeholder('n1', conv: 'k3');
      await b.store.close();
      expect(
        await peekK(m, 'n1', conv: 'k3', sk: a2.identityKey, si: aId),
        isNull,
      );
    });

    test("sk already stored for another person (carol's key, si alice): "
        'keyPeers names carol and the peek is refused', () async {
      final fromCarol = await send(c, 'c1m', 'carol here');
      ok(
        await b.engine.decrypt(
          peerUserId: cId,
          peerIdentityKey: c.identityKey,
          ciphertext: fromCarol.ciphertext,
          olmType: fromCarol.olmType,
        ),
      );
      final m = await send(a, 'f2', 'alice first');
      await placeholder('f2');
      await b.store.close();

      final r = readPeekRows(
        path: b.h.file.path,
        keyHex: b.keyHex,
        conversationId: 'k1',
        messageId: 'f2',
        senderKey: c.identityKey,
        senderId: aId,
      );
      expect(r!.keyPeers, [cId]);
      final clean = readPeekRows(
        path: b.h.file.path,
        keyHex: b.keyHex,
        conversationId: 'k1',
        messageId: 'f2',
        senderKey: a.identityKey,
        senderId: aId,
      );
      expect(clean!.keyPeers, isEmpty);
      expect(await peekK(m, 'f2', sk: c.identityKey, si: aId), isNull);
      // Control: the right key opens the same push.
      expect(await peekK(m, 'f2', sk: a.identityKey, si: aId), 'alice first');
    });

    // Slice 2 W1/W2: text opened with the push's own key (first contact) is
    // shown but NEVER saved; a chat not in the store is never saved.
    group('push_inbox write', () {
      List<Map<String, Object?>> rowsOf() {
        final db = sqlite3.open(b.h.file.path);
        try {
          db.execute("PRAGMA key = \"x'${b.keyHex}'\";");
          return [
            for (final r in db.select('SELECT * FROM push_inbox')) {...r},
          ];
        } finally {
          db.close();
        }
      }

      Future<String?> save(
        LockedText m,
        String id,
        List<String> codes, {
        String conv = 'k1',
        String? sk,
        String? si,
      }) => peekEncryptedText(
        storePath: b.h.file.path,
        storeKeyHex: b.keyHex,
        pickleKey: b.pk,
        ownerId: bId,
        conversationId: conv,
        messageId: id,
        ciphertext: m.ciphertext,
        olmType: m.olmType,
        senderKey: sk,
        senderId: si,
        budgetLeftMs: () => 3000,
        onInbox: codes.add,
      );

      test('W1: a first-contact push opened with sk/si shows the text and '
          'writes nothing; the store file is unchanged', () async {
        final m = await send(a, 'w1', 'first ever');
        await b.store.close();
        final before = await b.h.file.readAsBytes();
        final codes = <String>[];
        expect(
          await save(m, 'w1', codes, sk: a.identityKey, si: aId),
          'first ever',
        );
        expect(codes, isNot(contains('saved')));
        expect(rowsOf(), isEmpty);
        expect(await b.h.file.readAsBytes(), before);
      });

      test('control: once the session is stored, the next pre-key message '
          'on it is saved', () async {
        final first = await send(a, 'w0', 'opened by app');
        ok(
          await b.engine.decrypt(
            peerUserId: aId,
            peerIdentityKey: a.identityKey,
            ciphertext: first.ciphertext,
            olmType: first.olmType,
          ),
        );
        // Same outbound session (no reply yet): still a pre-key message
        // whose session id is stored.
        final m = ok(
          await a.engine.encrypt(
            bId,
            encodeEnvelope(id: 'w2', text: 'second'),
            peerIdentityKey: b.identityKey,
          ),
        );
        expect(m.olmType, 0);
        await b.store.close();
        final codes = <String>[];
        expect(
          await save(m, 'w2', codes, sk: a.identityKey, si: aId),
          'second',
        );
        expect(codes, ['saved']);
        expect(rowsOf().single['sender_id'], aId);
      });

      test('W2: a chat not in the store (si is the peer) is shown, not '
          'saved', () async {
        final m = await send(a, 'w3', 'no snapshot');
        await b.store.close();
        final codes = <String>[];
        expect(
          await save(m, 'w3', codes, conv: 'k3', sk: a.identityKey, si: aId),
          'no snapshot',
        );
        expect(codes, isNot(contains('saved')));
        expect(rowsOf(), isEmpty);
      });
    });
  });
}

/// Another connection (the app writing) holds an EXCLUSIVE lock for 300 ms.
void _holdLock(List<Object> args) {
  final db = sqlite3.open(args[0] as String);
  db.execute("PRAGMA key = \"x'${args[1]}'\";");
  db.execute('BEGIN EXCLUSIVE;');
  db.execute("UPDATE meta SET value = value WHERE key = 'owner_id';");
  final port = args[2] as SendPort;
  port.send('locked');
  sleep(const Duration(milliseconds: 300));
  db.execute('COMMIT;');
  db.close();
  port.send('released');
}

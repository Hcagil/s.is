// peekEncryptedText / readPeekRows against a REAL SQLite3 Multiple Ciphers
// store file written by the production store (DriftMessageStore,
// DriftSessionEngine over REAL Olm, DriftChatListSnapshotStore). Written from
// the peek contract (QA interface of Private Chats 4b Group G), never from the
// implementation: the file is opened read-only, nothing is ever written, any
// failure is null, and a held lock gives null after about 1 s, never a hang.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
import 'package:sis/features/chat/domain/message_envelope.dart';
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

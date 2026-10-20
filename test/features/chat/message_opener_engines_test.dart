// The receive path seam with TWO REAL Olm engines (OlmKeyEngine over the
// compiled vodozemac library) and two REAL encrypted store files: alice
// locks texts with her DriftSessionEngine, bob's StoreMessageOpener opens
// them with his. Real Olm cannot open one message twice, so every "opens
// once" claim here is checked by the engine itself. Written from the
// MessageOpener / SessionEngine contracts, never from the implementation.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import '../../support/opener_fakes.dart' show SlowStore;
import 'data/store/store_harness.dart' show StoreHarness, at;

final class _FixedPickleKey implements PickleKeyStore {
  _FixedPickleKey(this.key);
  final List<int> key;
  @override
  Future<List<int>> loadOrCreate() async => key;
  @override
  Future<void> delete() async {}
}

final class Phone {
  Phone._(this.userId, this.store, this.engine, this.claim, this.identity);

  final String userId;
  final DriftMessageStore store;
  final DriftSessionEngine engine;

  /// The keys a claim would hand out (a fresh one-time key each call).
  final ClaimedKeys Function() claim;

  /// The keys identityVerified hands out (no one-time key).
  final ClaimedKeys identity;

  static Future<Phone> make(String userId) async {
    final h = await StoreHarness.create();
    final store = h.open(owner: userId, key: await h.newKey());
    addTearDown(store.close);
    final olm = OlmKeyEngine();
    final pk = List<int>.generate(32, (i) => (i * 5 + userId.length) % 256);
    final account = await olm.create();
    account.generateOneTimeKeys(5);
    final otks = account.unpublishedOneTimeKeys;
    account.markPublished();
    expect(await DriftOlmPickleStore(store).save(account.pickle(pk)), isTrue);
    final engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: _FixedPickleKey(pk),
    );
    final sig = account.sign(
      deviceStatement(userId, account.identityKey, account.signingKey),
    );
    var next = 0;
    ClaimedKeys claim() => ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: sig,
      oneTimeKey: otks[next++],
      isFallback: false,
    );
    final identity = ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: sig,
      oneTimeKey: '',
      isFallback: false,
    );
    return Phone._(userId, store, engine, claim, identity);
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
  late bool keyOnline;

  setUp(() async {
    alice = await Phone.make('alice');
    bob = await Phone.make('bob');
    keyOnline = true;
  });

  /// bob's opener, as messageOpenerProvider wires it, over bob's phone.
  StoreMessageOpener opener({MessageStore? store}) {
    final o = StoreMessageOpener(
      me: () => bob.userId,
      engine: () => bob.engine,
      store: () => store ?? bob.store,
      peerKey: (id) async {
        if (!keyOnline) {
          return const Err(NetworkFailure('off', retryable: true));
        }
        expect(id, alice.userId);
        return Ok(alice.identity);
      },
    );
    addTearDown(o.dispose);
    return o;
  }

  var sessionMade = false;
  setUp(() => sessionMade = false);

  /// alice locks [text] for row [id] as the server will hold it.
  Future<Message> send(String id, String text, {int t = 0}) async {
    if (!sessionMade) {
      ok(await alice.engine.createOutbound(bob.userId, bob.claim()));
      sessionMade = true;
    }
    final l = ok(
      await alice.engine.encrypt(
        bob.userId,
        encodeEnvelope(id: id, text: text),
        peerIdentityKey: bob.identity.identityKey,
      ),
    );
    return Message(
      id: id,
      conversationId: 'c1',
      senderId: alice.userId,
      body: lockedBodyPlaceholder,
      createdAt: at(t),
      ciphertext: l.ciphertext,
      olmType: l.olmType,
    );
  }

  Future<String?> storedBody(String id) async {
    for (final m in await bob.store.newest('c1', limit: 500)) {
      if (m.id == id) return m.body;
    }
    return null;
  }

  test('pre-key first message: the real engine makes the session, the text '
      'shows, and it is stored before open returns (slow disk)', () async {
    final m0 = await send('m0', 'merhaba bob');
    expect(m0.olmType, 0);
    final slow = SlowStore(
      bob.store,
      writeDelay: const Duration(milliseconds: 300),
    );
    final out = await opener(store: slow).open([m0]);
    expect(out.single.body, 'merhaba bob');
    expect(out.single.ciphertext, isNull);
    expect(await storedBody('m0'), 'merhaba bob');
    expect(await bob.engine.hasSession(alice.userId), isTrue);
  });

  test('decrypt once: after a restart the same row comes from the stored '
      'sealed copy (real Olm could not open it again)', () async {
    final m0 = await send('m0', 'only once');
    expect((await opener().open([m0])).single.body, 'only once');
    final again = await opener().open([m0]);
    expect(again.single.body, 'only once');
    // Proof the engine really cannot open it twice.
    final second = await bob.engine.decrypt(
      peerUserId: alice.userId,
      peerIdentityKey: alice.identity.identityKey,
      ciphertext: m0.ciphertext!,
      olmType: m0.olmType!,
    );
    expect(second, isA<Err<String>>());
  });

  test(
    'duplicate delivery in one list opens once; both copies readable',
    () async {
      final m0 = await send('m0', 'twice delivered');
      final out = await opener().open([m0, m0]);
      expect(out.map((m) => m.body), ['twice delivered', 'twice delivered']);
      final ids = [for (final m in await bob.store.newest('c1')) m.id];
      expect(ids, ['m0']);
    },
  );

  test('out-of-order delivery in one list: every row opens, results in the '
      'original order', () async {
    final m0 = await send('m0', 'one', t: 0);
    final m1 = await send('m1', 'two', t: 1);
    final m2 = await send('m2', 'three', t: 2);
    final out = await opener().open([m2, m0, m1]);
    expect(out.map((m) => m.id), ['m2', 'm0', 'm1']);
    expect(out.map((m) => m.body), ['three', 'one', 'two']);
  });

  test('a waiting row (key lookup offline) is retried when a pre-key '
      'message of that sender opens, and emitted on reopened', () async {
    final m0 = await send('m0', 'first', t: 0);
    final m1 = await send('m1', 'waited for', t: 1);
    final o = opener();
    final got = <Message>[];
    final sub = o.reopened.listen(got.add);
    addTearDown(sub.cancel);

    keyOnline = false;
    final early = await o.open([m1]);
    expect(early.single.body, lockedBodyPlaceholder);
    expect(early.single.ciphertext, isNull);

    keyOnline = true;
    final out = await o.open([m0]);
    expect(out.single.body, 'first');
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (got.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(got.map((m) => (m.id, m.body)), [('m1', 'waited for')]);
  });
}

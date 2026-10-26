// Receive path security-gate cases 14-16 (added after the first contract):
// deletion wins over opened text, a failed store write after decrypt still
// shows the text once-only, and the waiting list never evicts on a repeat.
// Written from the contract, never from the implementation; qa fakes for
// the engine and peerKey, the REAL encrypted DriftMessageStore.

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../support/opener_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

Message locked(String id, {int t = 0, int olmType = 1}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'bob',
  body: lockedBodyPlaceholder,
  createdAt: at(t),
  ciphertext: ct(id),
  olmType: olmType,
);

Message deletedCopy(String id, {int t = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'bob',
  body: '',
  createdAt: at(t),
  deletion: MessageDeletion.placeholder,
);

void main() {
  late ScriptEngine engine;
  late DriftMessageStore real;
  late SlowStore store;

  setUp(() async {
    final h = await StoreHarness.create();
    real = h.open(owner: 'me', key: await h.newKey());
    addTearDown(real.close);
    store = SlowStore(real);
    engine = ScriptEngine();
  });

  StoreMessageOpener make() {
    final o = StoreMessageOpener(
      me: () => 'me',
      engine: () => engine,
      store: () => store,
      peerKey: FakePeerKeys().call,
    );
    addTearDown(o.dispose);
    return o;
  }

  Future<Message?> stored(String id) async {
    for (final m in await real.newest('c1', limit: 500)) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Pending until the pre-key row k0 opens; then each opens to "text <id>".
  void pendingUntilKey(Iterable<String> ids) {
    var session = false;
    for (final id in ids) {
      engine.answer[ct(id)] = () => session
          ? Ok(encodeEnvelope(id: id, text: 'text $id'))
          : const Err(SessionPendingFailure());
    }
    engine.answer[ct('k0')] = () {
      session = true;
      return Ok(encodeEnvelope(id: 'k0', text: 'key'));
    };
  }

  group('14 deletion wins', () {
    test(
      'a stored deleted row is returned as deleted, never decrypted text',
      () async {
        await real.upsertAll([deletedCopy('m1')]);
        engine.answer[ct('m1')] = () =>
            Ok(encodeEnvelope(id: 'm1', text: 'must not show'));
        final out = await make().open([locked('m1')]);
        expect(out.single.isDeleted, isTrue);
        expect(out.single.body, isNot('must not show'));
        expect(out.single.ciphertext, isNull);
        expect((await stored('m1'))?.isDeleted, isTrue);
      },
    );

    test('(a) waiting, then deleted by the sender, then a pre-key message: '
        'the retry neither emits nor stores the old row as readable', () async {
      pendingUntilKey(['w1']);
      final o = make();
      final got = <Message>[];
      final sub = o.reopened.listen(got.add);
      addTearDown(sub.cancel);
      await o.open([locked('w1', t: 1)]);
      await real.upsertAll([deletedCopy('w1', t: 1)]);
      await o.open([locked('k0', t: 2, olmType: 0)]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(got.where((m) => m.id == 'w1' && !m.isDeleted), isEmpty);
      expect((await stored('w1'))?.isDeleted, isTrue);
    });

    test('(b) the deletion lands between the server read and the decrypt: '
        'the late write does not clear it', () async {
      engine.answer[ct('m1')] = () =>
          Ok(encodeEnvelope(id: 'm1', text: 'too late'));
      engine.during = (c) => real.upsertAll([deletedCopy('m1')]);
      final out = await make().open([locked('m1')]);
      expect((await stored('m1'))?.isDeleted, isTrue);
      expect(out.single.body, isNot('too late'));
    });

    test('store: upsertAll never replaces a deleted row with a non-deleted '
        'one', () async {
      await real.upsertAll([deletedCopy('m1')]);
      await real.upsertAll([
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'bob',
          body: 'resurrected',
          createdAt: at(0),
        ),
      ]);
      expect((await stored('m1'))?.isDeleted, isTrue);
    });

    test('store: reconcilePage never replaces a deleted row with a '
        'non-deleted one', () async {
      await real.upsertAll([deletedCopy('m1')]);
      await real.reconcilePage('c1', [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'bob',
          body: 'resurrected',
          createdAt: at(0),
        ),
      ], reachedStart: false);
      expect((await stored('m1'))?.isDeleted, isTrue);
    });
  });

  group('15 the store write fails after decrypt', () {
    for (final mode in ['skipped', 'throws']) {
      test('($mode) the text still shows, and a second open of the run '
          'answers from memory', () async {
        if (mode == 'skipped') {
          store.dropWrites = true;
        } else {
          store.throwWrites = true;
        }
        engine.answer[ct('m1')] = () =>
            Ok(encodeEnvelope(id: 'm1', text: 'opened once'));
        final o = make();
        final out = await o.open([locked('m1')]);
        expect(out.single.body, 'opened once');
        final again = await o.open([locked('m1')]);
        expect(again.single.body, 'opened once');
        expect(engine.calls, hasLength(1));
      });
    }
  });

  group('16 waiting list', () {
    test('a row already waiting, seen again, does not evict another', () async {
      final ids = [for (var i = 0; i < 200; i++) 'w$i'];
      pendingUntilKey(ids);
      final o = make();
      final got = <String>{};
      final sub = o.reopened.listen((m) => got.add(m.id));
      addTearDown(sub.cancel);
      await o.open([for (var i = 0; i < 200; i++) locked('w$i', t: i)]);
      await o.open([locked('w199', t: 199)]); // seen again: still waiting
      await o.open([locked('k0', t: 999, olmType: 0)]);
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (got.length < 200 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(got, ids.toSet());
      // 200 real encrypted saves: ~7 s alone, ~17 s on a busy 4-core runner.
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

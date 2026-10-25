// StoreMessageOpener with the peer key cache, the key time limit and the
// pending-row retry timer, in fake time. Written from the contract of task
// "private chats open their messages fast", never from the implementation.
// The engine is the qa ScriptEngine; the key lookup is ControlledKeys, used
// for BOTH peerKey and the cache's fetch, as production wires
// identityVerified into both.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/application/peer_key_cache.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../support/opener_fakes.dart';
import '../../support/peer_key_fakes.dart';

const me = 'me';
const bob = 'bob';

Message locked(String id, {int t = 0, int olmType = 1}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: bob,
  body: lockedBodyPlaceholder,
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: t)),
  ciphertext: ct(id),
  olmType: olmType,
);

void main() {
  late ScriptEngine engine;
  late ControlledKeys keys;
  late MemoryMessageStore store;
  late String? whoAmI;

  setUp(() {
    engine = ScriptEngine();
    keys = ControlledKeys();
    store = MemoryMessageStore();
    whoAmI = me;
  });

  void opens(String id, [String? text]) =>
      engine.answer[ct(id)] = () =>
          Ok(encodeEnvelope(id: id, text: text ?? 'text $id'));

  void waits(String id) =>
      engine.answer[ct(id)] = () => const Err(SessionPendingFailure());

  StoreMessageOpener make(FakeAsync a) {
    keys.clock = a;
    return StoreMessageOpener(
      me: () => whoAmI,
      engine: () => engine,
      store: () => store,
      peerKey: keys.call,
      cache: PeerKeyCache(
        keys.call,
        now: () => a.getClock(DateTime(2026)).now(),
      ),
    );
  }

  /// Runs [f] in fake time for [d] and returns its value (null if not done).
  T? run<T>(
    FakeAsync a,
    Future<T> f, [
    Duration d = const Duration(seconds: 1),
  ]) {
    T? out;
    f.then((v) => out = v);
    a.elapse(d);
    return out;
  }

  group('peer key cache', () {
    test('normal rows of one peer over three open() calls: one key fetch', () {
      fakeAsync((a) {
        for (final id in ['m1', 'm2', 'm3', 'm4']) {
          opens(id);
        }
        final o = make(a);
        run(a, o.open([locked('m1'), locked('m2', t: 1)]));
        run(a, o.open([locked('m3', t: 2)]));
        final out = run(a, o.open([locked('m4', t: 3)]))!;
        expect(out.single.body, 'text m4');
        expect(keys.calls, [bob]);
        o.dispose();
      });
    });

    test('after the 5 min lifetime the key is fetched again', () {
      fakeAsync((a) {
        opens('m1');
        opens('m2');
        final o = make(a);
        run(a, o.open([locked('m1')]));
        a.elapse(const Duration(minutes: 5, seconds: 1));
        run(a, o.open([locked('m2', t: 1)]));
        expect(keys.calls, [bob, bob]);
        o.dispose();
      });
    });

    test('a pre-key row (olmType 0) always fetches fresh', () {
      fakeAsync((a) {
        opens('m1');
        opens('k1');
        opens('k2');
        final o = make(a);
        run(a, o.open([locked('m1')]));
        run(a, o.open([locked('k1', t: 1, olmType: 0)]));
        run(a, o.open([locked('k2', t: 2, olmType: 0)]));
        expect(keys.calls, [bob, bob, bob]);
        o.dispose();
      });
    });

    test('a row that goes pending drops the entry: the next normal row '
        'refetches', () {
      fakeAsync((a) {
        waits('m1');
        opens('m2');
        final o = make(a);
        final first = run(a, o.open([locked('m1')]))!;
        expect(first.single.body, lockedBodyPlaceholder);
        run(a, o.open([locked('m2', t: 1)]));
        expect(keys.calls, [bob, bob]);
        o.dispose();
      });
    });

    test('a row that is unreadable drops the entry: the next normal row '
        'refetches', () {
      fakeAsync((a) {
        opens('m2'); // m1 has no answer: Unreadable
        final o = make(a);
        run(a, o.open([locked('m1')]));
        run(a, o.open([locked('m2', t: 1)]));
        expect(keys.calls, [bob, bob]);
        o.dispose();
      });
    });

    test('a fresh pre-key key serves the normal rows after it in the same '
        'batch: one fetch, all open at once, nothing waits', () {
      fakeAsync((a) {
        opens('k0');
        opens('m1');
        opens('m2');
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        final out = run(
          a,
          o.open([
            locked('k0', olmType: 0),
            locked('m1', t: 1),
            locked('m2', t: 2),
          ]),
        )!;
        expect(out.map((m) => m.body), ['text k0', 'text m1', 'text m2']);
        expect(keys.calls, [bob]);
        a.elapse(const Duration(minutes: 1));
        expect(got, isEmpty);
        expect(engine.calls, hasLength(3));
        o.dispose();
      });
    });
  });

  group('key lookup time limit', () {
    test('a lookup over 8 s: the row stays the locked placeholder, is not '
        'dropped, and a later retry emits it on reopened', () {
      fakeAsync((a) {
        opens('m1', 'late hello');
        keys.mode = KeyMode.hang;
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        final f = o.open([locked('m1')]);
        List<Message>? out;
        f.then((v) => out = v);
        a.elapse(const Duration(seconds: 7));
        expect(out, isNull, reason: 'still inside the 8 s limit');
        a.elapse(const Duration(seconds: 2));
        expect(out, isNotNull, reason: 'open() must end after about 8 s');
        expect(out!.single.id, 'm1');
        expect(out!.single.body, lockedBodyPlaceholder);
        expect(engine.calls, isEmpty);
        keys.mode = KeyMode.ok;
        keys.releaseAll(); // the slow answer must not open it by itself
        a.elapse(const Duration(minutes: 3));
        expect(got.map((m) => m.id), ['m1']);
        expect(got.single.body, 'late hello');
        expect(got.single.ciphertext, isNull);
        o.dispose();
      });
    });
  });

  group('retry timer', () {
    test('pending rows are retried 5 s, 15 s, 45 s, 2 min, 5 min apart, '
        'then never again', () {
      fakeAsync((a) {
        keys.mode = KeyMode.offline;
        final o = make(a);
        run(a, o.open([locked('m1')]));
        a.elapse(const Duration(hours: 1));
        expect(keys.seconds, [0, 5, 20, 65, 185, 485]);
        o.dispose();
      });
    });

    test('the timer stops once nothing is pending', () {
      fakeAsync((a) {
        opens('m1');
        keys.mode = KeyMode.offline;
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        run(a, o.open([locked('m1')]));
        keys.mode = KeyMode.ok;
        a.elapse(const Duration(seconds: 6));
        expect(got.map((m) => m.id), ['m1']);
        final n = keys.calls.length;
        a.elapse(const Duration(hours: 1));
        expect(keys.calls, hasLength(n));
        expect(engine.calls, hasLength(1));
        o.dispose();
      });
    });

    test('nothing is fetched, decrypted or emitted after dispose()', () {
      fakeAsync((a) {
        opens('m1');
        keys.mode = KeyMode.offline;
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        run(a, o.open([locked('m1')]));
        final n = keys.calls.length;
        o.dispose();
        keys.mode = KeyMode.ok;
        a.elapse(const Duration(hours: 1));
        expect(keys.calls, hasLength(n));
        expect(engine.calls, isEmpty);
        expect(got, isEmpty);
      });
    });

    test('dispose during an in-flight retry: nothing emitted, nothing '
        'decrypted', () {
      fakeAsync((a) {
        opens('m1');
        keys.mode = KeyMode.offline;
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        run(a, o.open([locked('m1')]));
        keys.mode = KeyMode.hang;
        a.elapse(const Duration(seconds: 5, milliseconds: 100));
        expect(keys.seconds.last, 5, reason: 'the retry is waiting on its key');
        o.dispose();
        keys.mode = KeyMode.ok;
        keys.releaseAll();
        a.elapse(const Duration(minutes: 10));
        expect(got, isEmpty);
        expect(engine.calls, isEmpty, reason: 'decrypted after dispose()');
      });
    });

    test('dispose between rows of one retry pass: the next row is not '
        'decrypted and nothing is emitted', () {
      fakeAsync((a) {
        opens('m1');
        opens('m2');
        keys.mode = KeyMode.offline;
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        run(a, o.open([locked('m1'), locked('m2', t: 1)]));
        keys.mode = KeyMode.ok;
        engine.during = (_) async => o.dispose();
        a.elapse(const Duration(minutes: 10));
        expect(engine.calls, hasLength(1));
        expect(got, isEmpty);
      });
    });

    test('a new open() restarts the backoff: its first retry is 5 s later, '
        'even when the old timer was at a long step', () {
      fakeAsync((a) {
        keys.mode = KeyMode.offline;
        final o = make(a);
        run(a, o.open([locked('m1')]));
        a.elapse(const Duration(seconds: 199)); // retries 5, 20, 65, 185
        run(a, o.open([locked('m2', t: 1)])); // at 200 s
        a.elapse(const Duration(seconds: 10)); // to 211 s
        expect(keys.seconds, [0, 5, 20, 65, 185, 200, 205]);
        o.dispose();
      });
    });

    test('reset (signed-in user changed): the old pending rows are never '
        'retried', () {
      fakeAsync((a) {
        opens('m1');
        keys.mode = KeyMode.offline;
        final o = make(a);
        final got = <Message>[];
        o.reopened.listen(got.add);
        run(a, o.open([locked('m1')]));
        final before = keys.calls.length;
        whoAmI = 'someone-else';
        o.reset();
        keys.mode = KeyMode.ok;
        a.elapse(const Duration(minutes: 10));
        expect(keys.calls, hasLength(before), reason: 'old rows retried');
        expect(engine.calls, isEmpty);
        expect(got, isEmpty);
        // The new account gets a waiting row of its own: its retries must
        // not carry the old account's row along.
        waits('m3');
        run(a, o.open([locked('m3', t: 2)]));
        a.elapse(const Duration(minutes: 10));
        expect(engine.decrypted, isNot(contains(ct('m1'))));
        expect(got.where((m) => m.id == 'm1'), isEmpty);
        o.dispose();
      });
    });

    test('reset empties the peer key cache', () {
      fakeAsync((a) {
        opens('m1');
        opens('m2');
        final o = make(a);
        run(a, o.open([locked('m1')]));
        o.reset();
        run(a, o.open([locked('m2', t: 1)]));
        expect(keys.calls, [bob, bob]);
        o.dispose();
      });
    });
  });
}

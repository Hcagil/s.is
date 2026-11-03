// MessageOpener.openWaiting and the "open waiting rows before a new session
// retires the old ones" rule (a text sent just before the contact's key
// changed). Written from the MessageOpener contract, never from the
// implementation; the engine is the qa ScriptEngine (test/support).

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../support/opener_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

const me = 'me';
const bob = 'bob';
const carol = 'carol';

Message locked(String id, {String from = bob, int t = 0, int olmType = 1}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: lockedBodyPlaceholder,
      createdAt: at(t),
      ciphertext: ct(id),
      olmType: olmType,
    );

void main() {
  late ScriptEngine engine;
  late DriftMessageStore store;

  setUp(() async {
    final h = await StoreHarness.create();
    store = h.open(owner: me, key: await h.newKey());
    addTearDown(store.close);
    engine = ScriptEngine();
  });

  StoreMessageOpener make() {
    final o = StoreMessageOpener(
      me: () => me,
      engine: () => engine,
      store: () => store,
      peerKey: FakePeerKeys().call,
    );
    addTearDown(o.dispose);
    return o;
  }

  void pending(String id) =>
      engine.answer[ct(id)] = () => const Err(SessionPendingFailure());
  void opens(String id, String text) =>
      engine.answer[ct(id)] = () => Ok(encodeEnvelope(id: id, text: text));

  /// [o] opened [rows] and each came back locked (waiting for a session).
  Future<void> waiting(StoreMessageOpener o, List<Message> rows) async {
    for (final m in rows) {
      pending(m.id);
    }
    final out = await o.open(rows);
    for (final m in out) {
      expect(m.body, lockedBodyPlaceholder, reason: 'setup: ${m.id} waits');
    }
    engine.calls.clear();
  }

  test('a waiting type-1 row opens on openWaiting, comes out on reopened, '
      'and leaves the waiting set', () async {
    final o = make();
    await waiting(o, [locked('m1')]);
    final got = <Message>[];
    final sub = o.reopened.listen(got.add);
    addTearDown(sub.cancel);

    opens('m1', 'eski anahtarla');
    await o.openWaiting(bob);
    await pumpEventQueue();
    expect(engine.decrypted, [ct('m1')]);
    expect(got.single.id, 'm1');
    expect(got.single.body, 'eski anahtarla');
    expect(got.single.ciphertext, isNull);

    await o.openWaiting(bob);
    expect(engine.decrypted, [ct('m1')], reason: 'no longer waiting');
  });

  test('openWaiting(bob) never touches carol\'s waiting rows', () async {
    final o = make();
    await waiting(o, [locked('c1', from: carol)]);
    opens('c1', 'carol');
    await o.openWaiting(bob);
    expect(engine.calls, isEmpty);
  });

  test('a row still pending stays waiting and opens on a later call', () async {
    final o = make();
    await waiting(o, [locked('m1')]);
    await o.openWaiting(bob);
    expect(engine.decrypted, [ct('m1')]);
    opens('m1', 'sonra');
    final next = o.reopened.first;
    await o.openWaiting(bob);
    expect((await next.timeout(const Duration(seconds: 2))).body, 'sonra');
  });

  test('never throws: the engine crashing inside openWaiting', () async {
    final o = make();
    await waiting(o, [locked('m1')]);
    engine.throwFor.add(ct('m1'));
    await expectLater(o.openWaiting(bob), completes);
  });

  test('after dispose: a no-op, nothing decrypted, no throw', () async {
    final o = make();
    await waiting(o, [locked('m1')]);
    opens('m1', 'x');
    o.dispose();
    await expectLater(o.openWaiting(bob), completes);
    expect(engine.calls, isEmpty);
  });

  test('a pre-key (type 0) row from bob first retries bob\'s waiting rows, '
      'before its own decrypt', () async {
    final o = make();
    await waiting(o, [locked('m1')]);
    final got = <Message>[];
    final sub = o.reopened.listen(got.add);
    addTearDown(sub.cancel);

    opens('m1', 'eski');
    opens('p0', 'yeni');
    final out = await o.open([locked('p0', olmType: 0, t: 9)]);
    await pumpEventQueue();
    expect(out.single.body, 'yeni');
    expect(engine.decrypted.indexOf(ct('m1')), 0, reason: '${engine.calls}');
    expect(engine.decrypted, contains(ct('p0')));
    expect(got.map((m) => (m.id, m.body)), [('m1', 'eski')]);
  });

  test('a waiting row whose retry crashes the engine does not stop the '
      'pre-key row from opening', () async {
    final o = make();
    await waiting(o, [locked('m1')]);
    engine.throwFor.add(ct('m1'));
    opens('p0', 'yeni');
    final out = await o.open([locked('p0', olmType: 0, t: 9)]);
    expect(out.single.body, 'yeni');
  });
}

// The opener tells the screens which locked rows still wait for a session
// (onOpening): when a row starts waiting, when it opens, on forget and on
// reset. Written from the contract (t_d914623597), never from the code.
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

Message locked(String id, {int t = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: bob,
  body: lockedBodyPlaceholder,
  createdAt: at(t),
  ciphertext: ct(id),
  olmType: 1,
);

void main() {
  late ScriptEngine engine;
  late DriftMessageStore store;
  late List<List<String>> seen;

  setUp(() async {
    final h = await StoreHarness.create();
    store = h.open(owner: me, key: await h.newKey());
    addTearDown(store.close);
    engine = ScriptEngine();
    seen = [];
  });

  StoreMessageOpener make() {
    final o = StoreMessageOpener(
      me: () => me,
      engine: () => engine,
      store: () => store,
      peerKey: FakePeerKeys().call,
      onOpening: (rows) => seen.add([for (final m in rows) m.id]..sort()),
    );
    addTearDown(o.dispose);
    return o;
  }

  void pending(String id) =>
      engine.answer[ct(id)] = () => const Err(SessionPendingFailure());
  void opens(String id) =>
      engine.answer[ct(id)] = () => Ok(encodeEnvelope(id: id, text: 'hi'));

  test('a row that comes back locked is published as waiting', () async {
    final o = make();
    pending('m1');
    await o.open([locked('m1')]);
    expect(seen, isNotEmpty);
    expect(seen.last, ['m1']);
  });

  test('a waiting row that opens is published as gone', () async {
    final o = make();
    pending('m1');
    await o.open([locked('m1')]);
    expect(seen.last, ['m1']);
    opens('m1');
    await o.openWaiting(bob);
    await pumpEventQueue();
    expect(seen.last, isEmpty);
  });

  test('forget removes the row from the published list', () async {
    final o = make();
    pending('m1');
    await o.open([locked('m1')]);
    o.forget('m1');
    expect(seen.last, isEmpty);
  });

  test('reset empties the published list', () async {
    final o = make();
    pending('m1');
    await o.open([locked('m1')]);
    o.reset();
    expect(seen.last, isEmpty);
  });
}

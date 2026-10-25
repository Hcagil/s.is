// t_93dcd3767e (S3): on a history path (fresh false) in a held chat, an
// unstored plain row dated inside the range this phone already holds
// (syncState.contiguousFrom) shows locked; outside it, the date rule alone.
// Written from the contract, never from the implementation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../support/opener_fakes.dart';
import '../../support/security_code_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

Message locked(String id, {int t = 0, String sender = 'bob'}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: sender,
  body: lockedBodyPlaceholder,
  createdAt: at(t),
  ciphertext: ct(id),
  olmType: 1,
);
Message plain(String id, {int t = 0, String body = 'plain text'}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'bob',
  body: body,
  createdAt: at(t),
);

void main() {
  late ScriptEngine engine;
  late DriftMessageStore real;
  late FakeSecurityCodeStore memory;
  setUp(() async {
    final h = await StoreHarness.create();
    real = h.open(owner: 'me', key: await h.newKey());
    addTearDown(real.close);
    engine = ScriptEngine();
    memory = FakeSecurityCodeStore();
  });
  StoreMessageOpener make() {
    final o = StoreMessageOpener(
      me: () => 'me',
      engine: () => engine,
      store: () => real,
      peerKey: FakePeerKeys().call,
      memory: () => memory,
    );
    addTearDown(o.dispose);
    return o;
  }

  void opens(String id, String text) =>
      engine.answer[ct(id)] = () => Ok(encodeEnvelope(id: id, text: text));
  // tests here
  test('A: locked body when contiguousFrom set and createdAt after', () async {
    await real.reconcilePage('c1', [
      plain('p2', t: 2, body: 'kept'),
      plain('p3', t: 3, body: 'kept 3'),
    ], reachedStart: false);
    opens('l1', 'locked hello');
    await make().open([locked('l1', t: 5)]);
    expect(memory.held['c1'], equals(at(5)));
    final rows = await make().open([
      plain('f1', t: 3, body: 'forged'),
    ], fresh: false);
    expect(rows.length, 1);
    expect(rows[0].body, equals(lockedBodyPlaceholder));
  });

  test('B: body kept when createdAt before contiguousFrom', () async {
    await real.reconcilePage('c1', [
      plain('p2', t: 2, body: 'kept'),
      plain('p3', t: 3, body: 'kept 3'),
    ], reachedStart: false);
    opens('l1', 'locked hello');
    await make().open([locked('l1', t: 5)]);
    expect(memory.held['c1'], equals(at(5)));
    final rows = await make().open([
      plain('f0', t: 1, body: 'old'),
    ], fresh: false);
    expect(rows.length, 1);
    expect(rows[0].body, equals('old'));
  });

  test('C: body kept when no syncState', () async {
    opens('l1', 'locked hello');
    await make().open([locked('l1', t: 5)]);
    expect(memory.held['c1'], equals(at(5)));
    final rows = await make().open([
      plain('f2', t: 3, body: 'old2'),
    ], fresh: false);
    expect(rows.length, 1);
    expect(rows[0].body, equals('old2'));
  });

  test('D: locked body when createdAt exactly at contiguousFrom', () async {
    await real.reconcilePage('c1', [
      plain('p2', t: 2, body: 'kept'),
      plain('p3', t: 3, body: 'kept 3'),
    ], reachedStart: false);
    opens('l1', 'locked hello');
    await make().open([locked('l1', t: 5)]);
    expect(memory.held['c1'], equals(at(5)));
    final rows = await make().open([
      plain('f3', t: 2, body: 'edge'),
    ], fresh: false);
    expect(rows.length, 1);
    expect(rows[0].body, equals(lockedBodyPlaceholder));
  });
}

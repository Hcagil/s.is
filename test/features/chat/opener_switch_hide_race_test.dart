
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';
import 'package:sis/features/chat/domain/message_store.dart';

import '../../support/opener_fakes.dart';
import 'data/store/store_harness.dart' show StoreHarness, at;

Message locked(String id, {String from = 'bob', int t = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: lockedBodyPlaceholder,
  createdAt: at(t),
  ciphertext: ct(id),
  olmType: 1,
);

Future<bool> has(DriftMessageStore s, String id) async {
  final rows = await s.newest('c1', limit: 500);
  return rows.any((m) => m.id == id);
}

void main() {
  late ScriptEngine engine;
  late FakePeerKeys peerKeys;
  late StoreHarness oldHarness;
  late StoreHarness newHarness;
  late DriftMessageStore oldReal;
  late DriftMessageStore newReal;
  late SlowStore oldStore;
  late SlowStore newStore;
  late String? whoAmI;
  late MessageStore current;
  late StoreMessageOpener o;

  setUp(() async {
    engine = ScriptEngine();
    peerKeys = FakePeerKeys();
    oldHarness = await StoreHarness.create();
    newHarness = await StoreHarness.create();
    oldReal = oldHarness.open(owner: 'me', key: await oldHarness.newKey());
    newReal = newHarness.open(owner: 'other', key: await newHarness.newKey());
    oldStore = SlowStore(oldReal);
    newStore = SlowStore(newReal);
    whoAmI = 'me';
    current = oldStore;
    o = StoreMessageOpener(
      me: () => whoAmI,
      engine: () => engine,
      store: () => current,
      peerKey: peerKeys.call,
    );
    addTearDown(o.dispose);
    addTearDown(oldReal.close);
    addTearDown(newReal.close);
  });

  void switchAccount(StoreMessageOpener opener) {
    whoAmI = 'other';
    current = newStore;
    opener.reset();
  }

  group('REPRO A account switch while a decrypt is in flight', () {
    test('a decrypt in flight when the account switches writes nothing to the new account store', () async {
      engine.answer[ct('m1')] = () =>
          Ok(encodeEnvelope(id: 'm1', text: 'secret', card: null));
      engine.during = (_) async {
        switchAccount(o);
      };
      await o.open([locked('m1')]);
      expect(
        await has(newReal, 'm1'),
        isFalse,
        reason: 'old account row leaked into the new account store',
      );
      expect(
        newStore.upserted,
        isEmpty,
        reason: 'old account row leaked into the new account store',
      );
    });

    test('switch while the store write is still running', () async {
      engine.answer[ct('m1')] = () =>
          Ok(encodeEnvelope(id: 'm1', text: 'secret', card: null));
      oldStore.writeDelay = Duration(milliseconds: 100);
      final f = o.open([locked('m1')]); // do not await
      await Future.delayed(Duration(milliseconds: 30));
      switchAccount(o);
      await f;
      expect(
        await has(newReal, 'm1'),
        isFalse,
        reason: 'old account row leaked into the new account store',
      );
      expect(
        newStore.upserted,
        isEmpty,
        reason: 'old account row leaked into the new account store',
      );
    });

    test('switch after open started but before the engine answers', () async {
      final e = ScriptEngine(latency: Duration(milliseconds: 50));
      e.answer[ct('m1')] = () =>
          Ok(encodeEnvelope(id: 'm1', text: 'secret', card: null));
      final opener = StoreMessageOpener(
        me: () => whoAmI,
        engine: () => e,
        store: () => current,
        peerKey: peerKeys.call,
      );
      addTearDown(opener.dispose);
      final f = opener.open([locked('m1')]);
      await Future.delayed(Duration(milliseconds: 10));
      switchAccount(opener);
      await f;
      expect(
        await has(newReal, 'm1'),
        isFalse,
        reason: 'old account row leaked into the new account store',
      );
      expect(
        newStore.upserted,
        isEmpty,
        reason: 'old account row leaked into the new account store',
      );
    });
  });

  group('REPRO B hide while a decrypt is in flight', () {
    test('a message hidden during its decrypt is not written back', () async {
      engine.answer[ct('m1')] = () =>
          Ok(encodeEnvelope(id: 'm1', text: 'secret', card: null));
      await oldReal.upsertAll([locked('m1')]); // stored locked
      engine.during = (_) async {
        o.forget('m1');
        await oldStore.remove('m1');
      };
      await o.open([locked('m1')]);
      expect(
        await has(oldReal, 'm1'),
        isFalse,
        reason: 'hidden message came back',
      );
    });

    test('a message hidden while the plaintext write waits on the disk is not written back', () async {
      engine.answer[ct('m1')] = () =>
          Ok(encodeEnvelope(id: 'm1', text: 'secret', card: null));
      await oldReal.upsertAll([locked('m1')]); // stored locked
      oldStore.writeDelay = Duration(milliseconds: 100);
      final f = o.open([locked('m1')]);
      await Future.delayed(Duration(milliseconds: 30));
      o.forget('m1');
      await oldStore.remove('m1');
      await f;
      await Future.delayed(Duration(milliseconds: 150));
      expect(
        await has(oldReal, 'm1'),
        isFalse,
        reason: 'hidden message came back',
      );
    });
  });
}

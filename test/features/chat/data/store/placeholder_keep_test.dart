// Written from the MessageStore placeholder rule contract, never from the implementation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'store_harness.dart';

void main() {
  late DriftMessageStore store;
  late StoreHarness harness;

  setUp(() async {
    harness = await StoreHarness.create();
    store = harness.open(owner: 'u1', key: await harness.newKey());
    addTearDown(store.close);
  });

  Future<String?> bodyOf(String id) async {
    final rows = await store.newest('c1');
    for (final m in rows) {
      if (m.id == id) return m.body;
    }
    return null;
  }

  test('upsertAll skips placeholder when stored row is readable', () async {
    await store.upsertAll([msg('m1')]); // stored 'hello'
    await store.upsertAll([msg('m1', body: lockedBodyPlaceholder)]);
    expect(await bodyOf('m1'), equals('hello'));
  });

  test('reconcilePage skips placeholder when stored row is readable', () async {
    await store.upsertAll([msg('m1')]); // stored 'hello'
    await store.reconcilePage('c1', [
      msg('m1', body: lockedBodyPlaceholder),
    ], reachedStart: false);
    expect(await bodyOf('m1'), equals('hello'));
  });

  test('upsertAll overwrites with normal body', () async {
    await store.upsertAll([msg('m1')]); // stored 'hello'
    await store.upsertAll([msg('m1', body: 'edited')]);
    expect(await bodyOf('m1'), equals('edited'));
  });

  test('upsertAll writes placeholder when no row exists', () async {
    await store.upsertAll([msg('m1', body: lockedBodyPlaceholder)]);
    expect(await bodyOf('m1'), equals(lockedBodyPlaceholder));
  });

  test('upsertAll overwrites placeholder with normal body', () async {
    await store.upsertAll([msg('m1', body: lockedBodyPlaceholder)]);
    await store.upsertAll([msg('m1', body: 'opened')]);
    expect(await bodyOf('m1'), equals('opened'));
  });

  test('upsertAll sets deletion on placeholder', () async {
    await store.upsertAll([msg('m1')]); // stored 'hello'
    await store.upsertAll([
      msg(
        'm1',
        body: lockedBodyPlaceholder,
        deletion: MessageDeletion.placeholder,
      ),
    ]);
    final rows = await store.newest('c1');
    final m = rows.firstWhere((m) => m.id == 'm1');
    expect(m.isDeleted, isTrue);
  });

  test(
    'upsertAll batch: placeholder skip does not drop other messages',
    () async {
      await store.upsertAll([msg('m1')]); // stored 'hello'
      await store.upsertAll([
        msg('m1', body: lockedBodyPlaceholder),
        msg('m2', body: 'new', t: 1),
      ]);
      expect(await bodyOf('m1'), equals('hello'));
      expect(await bodyOf('m2'), equals('new'));
    },
  );

  test(
    'reconcilePage batch: placeholder skip does not delete stored row',
    () async {
      await store.upsertAll([msg('m1')]); // stored 'hello'
      await store.reconcilePage('c1', [
        msg('m1', body: lockedBodyPlaceholder),
        msg('m2', body: 'new', t: 1),
      ], reachedStart: false);
      expect(await bodyOf('m1'), equals('hello'));
      expect(await bodyOf('m2'), equals('new'));
    },
  );
}

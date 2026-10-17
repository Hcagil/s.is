// MessageStore.extendOlder over a REAL encrypted DriftMessageStore (temp
// file). Written from the contract only:
// - no sync row: nothing happens (no rows stored either);
// - contiguousFrom becomes min(previous, page oldest), never raised;
// - newestAt is never moved; nothing is deleted;
// - reachedStart marks the chat complete, an empty page included.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/message.dart';

import 'store_harness.dart';

List<Message> _rows(List<int> ts) => [for (final t in ts) msg('m$t', t: t)];

void main() {
  late DriftMessageStore store;

  setUp(() async {
    final h = await StoreHarness.create();
    store = h.open(owner: 'u1', key: await h.newKey());
    addTearDown(store.close);
  });

  /// The chat's newest page is stored first, as the fill does: rows 10..12.
  Future<void> seeded() =>
      store.reconcilePage('c1', _rows([10, 11, 12]), reachedStart: false);

  test('a chat with no sync row: nothing is stored', () async {
    await store.extendOlder('c1', _rows([1, 2]), reachedStart: true);
    expect(await store.syncState('c1'), isNull);
    expect(await store.newest('c1'), isEmpty);
  });

  test('an older page is stored and lowers contiguousFrom to its oldest '
      'row; newestAt stays', () async {
    await seeded();
    await store.extendOlder('c1', _rows([5, 6, 7]), reachedStart: false);
    final s = (await store.syncState('c1'))!;
    expect(s.contiguousFrom?.toUtc(), at(5));
    expect(s.newestAt?.toUtc(), at(12));
    expect(s.complete, isFalse);
    expect(ids(await store.newest('c1', limit: 100)), [
      'm5',
      'm6',
      'm7',
      'm10',
      'm11',
      'm12',
    ]);
  });

  test('a page newer than contiguousFrom never raises it', () async {
    await seeded();
    await store.extendOlder('c1', _rows([4]), reachedStart: false);
    await store.extendOlder('c1', _rows([8, 11]), reachedStart: false);
    final s = (await store.syncState('c1'))!;
    expect(
      s.contiguousFrom?.toUtc(),
      at(4),
      reason: 'min(previous, page oldest)',
    );
  });

  test('a row newer than newestAt does not move newestAt', () async {
    await seeded();
    await store.extendOlder('c1', _rows([3, 20]), reachedStart: false);
    final s = (await store.syncState('c1'))!;
    expect(s.newestAt?.toUtc(), at(12));
    expect(s.contiguousFrom?.toUtc(), at(3));
  });

  test('nothing stored is deleted, even inside the page range', () async {
    await seeded();
    await store.upsertAll(_rows([6]));
    await store.extendOlder('c1', _rows([5, 7]), reachedStart: false);
    expect(ids(await store.newest('c1', limit: 100)), contains('m6'));
  });

  test('reachedStart marks the chat complete', () async {
    await seeded();
    await store.extendOlder('c1', _rows([1, 2]), reachedStart: true);
    final s = (await store.syncState('c1'))!;
    expect(s.complete, isTrue);
    expect(s.contiguousFrom?.toUtc(), at(1));
    expect(s.newestAt?.toUtc(), at(12));
  });

  test('an empty page with reachedStart marks the chat complete and keeps '
      'contiguousFrom', () async {
    await seeded();
    await store.extendOlder('c1', const [], reachedStart: true);
    final s = (await store.syncState('c1'))!;
    expect(s.complete, isTrue);
    expect(s.contiguousFrom?.toUtc(), at(10));
    expect(s.newestAt?.toUtc(), at(12));
  });

  test('an empty page without reachedStart changes nothing', () async {
    await seeded();
    await store.extendOlder('c1', const [], reachedStart: false);
    final s = (await store.syncState('c1'))!;
    expect(s.complete, isFalse);
    expect(s.contiguousFrom?.toUtc(), at(10));
    expect(s.newestAt?.toUtc(), at(12));
  });

  test('another chat is not touched', () async {
    await seeded();
    await store.reconcilePage('c2', [
      msg('x9', conv: 'c2', t: 9),
    ], reachedStart: false);
    await store.extendOlder('c1', _rows([1]), reachedStart: true);
    final s2 = (await store.syncState('c2'))!;
    expect(s2.contiguousFrom?.toUtc(), at(9));
    expect(s2.complete, isFalse);
  });
}

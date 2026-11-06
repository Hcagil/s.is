// reconcilePage on a REAL encrypted DriftMessageStore, from the MessageStore
// contract (lib/features/chat/domain/message_store.dart, reconcilePage doc):
// it deletes only stored rows "of the same time range" the page covers. A
// row newer than the page's newest row (it landed by push or realtime while
// the page was in flight) is outside that range and must stay; an empty page
// that is not the first-message page covers no range, so it deletes nothing.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'store_harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late DriftMessageStore s;

  setUp(() async {
    final h = await StoreHarness.create();
    s = h.open(owner: 'bob', key: await h.newKey());
    addTearDown(s.close);
  });

  test('a stored row newer than the page survives reconcile', () async {
    await s.upsertAll([msg('a', t: 1), msg('b', t: 2), msg('live', t: 10)]);
    await s.reconcilePage('c1', [
      msg('a', t: 1),
      msg('b', t: 2),
    ], reachedStart: false);
    expect(ids(await s.newest('c1')), ['a', 'b', 'live']);
  });

  // Control: the delete itself still works, so a green newer-row test is not
  // just a reconcile that deletes nothing.
  test(
    'a row inside the page range that the server dropped is deleted',
    () async {
      await s.upsertAll([msg('a', t: 1), msg('gone', t: 2), msg('b', t: 3)]);
      await s.reconcilePage('c1', [
        msg('a', t: 1),
        msg('b', t: 3),
      ], reachedStart: false);
      expect(ids(await s.newest('c1')), ['a', 'b']);
    },
  );

  test('an empty page that is not the final page deletes nothing', () async {
    await s.upsertAll([msg('a', t: 1), msg('b', t: 2)]);
    await s.reconcilePage('c1', const [], reachedStart: false);
    expect(ids(await s.newest('c1')), ['a', 'b']);
  });
}

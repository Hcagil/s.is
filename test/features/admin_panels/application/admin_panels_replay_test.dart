import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;

  Future<void> openIt() => ctrl.open('reason');

  AdminPanelsState st() => c.read(adminPanelsProvider);

  List<String> ids() => [
    for (final i in st().snapshot.toJson()['items'] as List)
      (i as Map)['id'] as String,
  ];

  int resyncs() => repo.sent.where((m) => m['kind'] == 'resync').length;

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminClockProvider.overrideWithValue(() => DateTime.utc(2026, 1, 1)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  // rows with seq <= persisted last seq are ignored on the first fetch
  test(
    'rows with seq <= persisted last seq are ignored on the first fetch',
    () async {
      repo.downSeq[1] = 5;
      repo.fetchQueue = [
        [
          snapRow(1, 3, cursor: 5, items: [qItem('Q-OLD')]),
          deltaRow(2, 6, cursor: 6, items: [qItem('Q-NEW')]),
        ],
      ];
      await openIt();
      await ctrl.refresh();
      expect(ids(), isEmpty);
      expect(st().hasSnapshot, isFalse);
      expect(store.saved, isNull);
    },
  );

  // a row equal to the persisted last seq is ignored too
  test('a row equal to the persisted last seq is ignored too', () async {
    repo.downSeq[1] = 5;
    repo.fetchQueue = [
      [
        snapRow(1, 5, cursor: 5, items: [qItem('Q-OLD')]),
        deltaRow(2, 6, cursor: 6, items: [qItem('Q-NEW')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(ids(), isEmpty);
    expect(st().hasSnapshot, isFalse);
  });

  // newer rows after the persisted seq still apply
  test('newer rows after the persisted seq still apply', () async {
    repo.downSeq[1] = 5;
    repo.fetchQueue = [
      [
        snapRow(1, 6, cursor: 5, items: [qItem('Q-1')]),
        deltaRow(2, 7, cursor: 6, items: [qItem('Q-2')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(ids(), unorderedEquals(['q:Q-1', 'q:Q-2']));
  });

  // a delta after a gap is not applied and not saved, and a resync is asked
  test(
    'a delta after a gap is not applied and not saved, and a resync is asked',
    () async {
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
          deltaRow(2, 3, cursor: 6, items: [qItem('Q-3')]),
        ],
      ];
      await openIt();
      await ctrl.refresh();
      expect(ids(), ['q:Q-1']);
      expect(st().snapshot.cursor, 5);
      expect(store.saved!.snapshot.cursor, 5);
      expect(resyncs(), 1);
    },
  );

  // no delta of the batch is applied after the gap
  test('no delta of the batch is applied after the gap', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
        deltaRow(2, 2, cursor: 6, items: [qItem('Q-2')]),
        deltaRow(3, 4, cursor: 7, items: [qItem('Q-4')]),
        deltaRow(4, 5, cursor: 8, items: [qItem('Q-5')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(ids(), unorderedEquals(['q:Q-1', 'q:Q-2']));
    expect(st().snapshot.cursor, 6);
    expect(store.saved!.snapshot.cursor, 6);
    expect(resyncs(), 1);
  });

  // a last row of another epoch does not deny the batch
  test('a last row of another epoch does not deny the batch', () async {
    repo.downSeq[1] = 5;
    repo.fetchQueue = [
      [
        snapRow(1, 6, cursor: 5, items: [qItem('Q-1')]),
        deltaRow(2, 1, cursor: 9, items: [qItem('Q-X')], epoch: 2),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(ids(), ['q:Q-1']);
  });

  // a last row of another epoch does not let old rows through
  test('a last row of another epoch does not let old rows through', () async {
    repo.downSeq[1] = 5;
    repo.fetchQueue = [
      [
        snapRow(1, 3, cursor: 5, items: [qItem('Q-OLD')]),
        deltaRow(2, 9, cursor: 9, items: [qItem('Q-X')], epoch: 2),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(ids(), isEmpty);
    expect(st().hasSnapshot, isFalse);
  });
}

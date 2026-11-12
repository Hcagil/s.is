import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot_store.dart';

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
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  test('a delta before any snapshot is not applied', () async {
    repo.fetchQueue = [
      [
        deltaRow(1, 1, cursor: 3, items: [qItem('Q-1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(st().hasSnapshot, isFalse);
    expect(ids(), isEmpty);
  });

  test('a snapshot then a newer delta: added and removed items', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1'), qItem('Q-2')]),
      ],
      [
        deltaRow(
          2,
          2,
          cursor: 6,
          items: [qItem('Q-3'), qItem('Q-1', removed: true)],
        ),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    await ctrl.refresh();
    expect(st().hasSnapshot, isTrue);
    expect(ids(), unorderedEquals(['q:Q-2', 'q:Q-3']));
    expect(st().snapshot.cursor, 6);
  });

  test(
    'a delta whose cursor is not newer than the snapshot is ignored',
    () async {
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
          deltaRow(2, 2, cursor: 5, items: [qItem('Q-9')]),
          deltaRow(3, 3, cursor: 4, items: [qItem('Q-8')]),
        ],
      ];
      await openIt();
      await ctrl.refresh();
      expect(ids(), ['q:Q-1']);
      expect(st().snapshot.cursor, 5);
    },
  );

  test('a replayed or older sequence is refused', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 5, cursor: 5, items: [qItem('Q-1')]),
        deltaRow(2, 5, cursor: 6, items: [qItem('Q-9')]),
        deltaRow(3, 4, cursor: 6, items: [qItem('Q-7')]),
        deltaRow(4, 6, cursor: 7, items: [qItem('Q-8')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(ids(), unorderedEquals(['q:Q-1', 'q:Q-8']));
    expect(ids(), isNot(contains('q:Q-9')));
    expect(ids(), isNot(contains('q:Q-7')));
  });

  test('resync is asked at most once a minute', () async {
    await openIt();
    await ctrl.refresh();
    await ctrl.refresh();
    await ctrl.refresh();
    expect(resyncs(), 1);
    expect(repo.sent.first['kind'], 'resync');
  });

  test('a saved snapshot shows after unlock and fetching goes on after its last id', () async {
    store.saved = AdminSavedSnapshot(
      epoch: 1,
      lastId: 9,
      snapshot: AdminSnapshot.full([qItem('Q-5')], cursor: 4, truncated: false),
    );
    await openIt();
    expect(st().hasSnapshot, isTrue);
    expect(ids(), unorderedEquals(['q:Q-5']));
    await ctrl.refresh();
    expect(repo.fetchCalls.first, 9);
  });

  test('a saved snapshot of another epoch is cleared and not shown', () async {
    store.saved = AdminSavedSnapshot(
      epoch: 2,
      lastId: 9,
      snapshot: AdminSnapshot.full([qItem('Q-5')], cursor: 4, truncated: false),
    );
    await openIt();
    expect(st().hasSnapshot, isFalse);
    expect(store.saved, isNull);
  });

  test('a complete snapshot is saved on the phone', () async {
    repo.fetchQueue = [
      [
        snapRow(7, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(store.saved, isNotNull);
    expect(store.saved!.epoch, 1);
    expect(store.saved!.lastId, 7);
    expect(store.saved!.snapshot.cursor, 5);
  });
}

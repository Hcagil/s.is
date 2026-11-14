// test/features/admin_panels/application/admin_seen_reset_test.dart
import 'package:sis/core/failure.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot_store.dart';
import 'package:sis/features/admin_panels/domain/admin_seen_store.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

import 'admin_fakes.dart';

class RecordingSeenStore implements AdminSeenStore {
  Map<String, Set<String>>? saved;
  int clearCalls = 0;
  int saveCalls = 0;

  @override
  Future<Map<String, Set<String>>?> load() async => saved == null
      ? null
      : {
          for (final e in saved!.entries) e.key: {...e.value},
        };

  @override
  Future<void> save(Map<String, Set<String>> seen) async {
    saveCalls++;
    saved = {
      for (final e in seen.entries) e.key: {...e.value},
    };
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    saved = null;
  }
}

bool holds(RecordingSeenStore s, String id) =>
    s.saved?.values.any((v) => v.contains(id)) ?? false;

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late RecordingSeenStore seen;

  Future<void> openIt() => ctrl.open('reason');

  AdminPanelsState st() => c.read(adminPanelsProvider);

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    seen = RecordingSeenStore();
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  test('an epoch change clears the seen store', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    ctrl.markSeen('questions');
    await pumpEventQueue();
    expect(holds(seen, 'Q-1') || holds(seen, 'q:Q-1'), isTrue);

    repo.statusResult = const Ok(AdminStatus(AdminLinkPhase.linked, epoch: 2));
    repo.fetchQueue = [<AdminRow>[]];
    await ctrl.refresh();
    await pumpEventQueue();
    expect(holds(seen, 'Q-1'), isFalse);
    expect(holds(seen, 'q:Q-1'), isFalse);
    expect(seen.clearCalls, greaterThanOrEqualTo(1));
  });

  test(
    'after an epoch change the first snapshot is the new baseline',
    () async {
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
        ],
      ];
      seen.saved = {
        'questions': {'stale-x'},
        'talk': <String>{},
        'tasks': <String>{},
      };
      await openIt();
      await ctrl.refresh();
      ctrl.markSeen('questions');
      await pumpEventQueue();

      repo.statusResult = const Ok(
        AdminStatus(AdminLinkPhase.linked, epoch: 2),
      );
      repo.fetchQueue = [
        [
          snapRow(
            2,
            1,
            epoch: 2,
            snapId: 's2',
            cursor: 3,
            items: [qItem('Q-7'), qItem('Q-8')],
          ),
        ],
        [
          deltaRow(3, 2, epoch: 2, cursor: 4, items: [qItem('Q-9')]),
        ],
      ];
      await ctrl.refresh();
      await pumpEventQueue();
      expect(st().newCounts['questions'] ?? 0, 0);
      expect(holds(seen, 'stale-x'), isFalse);

      await ctrl.refresh();
      await pumpEventQueue();
      expect(st().newCounts['questions'] ?? 0, 1);
    },
  );

  test('losing the link clears the seen store', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    ctrl.markSeen('questions');
    await pumpEventQueue();
    expect(holds(seen, 'Q-1') || holds(seen, 'q:Q-1'), isTrue);

    repo.statusResult = const Ok(AdminStatus(AdminLinkPhase.changed, epoch: 1));
    repo.fetchQueue = [<AdminRow>[]];
    await ctrl.refresh();
    await pumpEventQueue();
    expect(holds(seen, 'Q-1'), isFalse);
    expect(holds(seen, 'q:Q-1'), isFalse);
    expect(seen.clearCalls, greaterThanOrEqualTo(1));
  });

  test('a saved snapshot of another epoch drops the seen ids too', () async {
    store.saved = AdminSavedSnapshot(
      epoch: 2,
      lastId: 9,
      snapshot: AdminSnapshot.full([qItem('Q-5')], cursor: 4, truncated: false),
    );
    seen.saved = {
      'questions': {'Q-5', 'q:Q-5', 'stale-x'},
      'talk': <String>{},
      'tasks': <String>{},
    };
    repo.fetchQueue = [];
    await openIt();
    await pumpEventQueue();
    expect(store.saved, isNull);
    expect(holds(seen, 'stale-x'), isFalse);
  });

  test('lock drops the seen ids held in memory', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    ctrl.markSeen('questions');
    await pumpEventQueue();
    expect(st().seen, isNotNull);
    ctrl.lock();
    expect(st().seen, isNull);
  });
}

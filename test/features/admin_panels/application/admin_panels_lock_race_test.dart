// test/features/admin_panels/application/admin_panels_lock_race_test.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot_store.dart';

import 'admin_fakes.dart';

/// A repository that delays the completion of [status] until
/// [statusGate] is completed. It records whether the status call
/// has started in [statusStarted].
class SlowStatusRepository extends FakeAdminRepository {
  final Completer<void> statusGate = Completer<void>();
  bool statusStarted = false;

  @override
  Future<Result<AdminStatus?>> status() async {
    statusStarted = true;
    await statusGate.future;
    return super.status();
  }
}

/// A snapshot store that delays the completion of [load] until
/// [loadGate] is completed. It records whether the load call
/// has started in [loadStarted].
class SlowSnapshotStore extends FakeAdminSnapshotStore {
  final Completer<void> loadGate = Completer<void>();
  bool loadStarted = false;

  @override
  Future<AdminSavedSnapshot?> load() async {
    loadStarted = true;
    await loadGate.future;
    return super.load();
  }
}

void main() {
  test(
    'the phone locks while status is still running after the unlock succeeded',
    () async {
      final repo = SlowStatusRepository();
      // unlock succeeds immediately
      final unlock = FakeAdminUnlock();
      // snapshot store
      final store = FakeAdminSnapshotStore();

      // prepare a snapshot that would be fetched if panels opened
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
        ],
      ];

      final c = ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(unlock),
          adminSnapshotStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      // listen to provider to trigger state changes
      c.listen(adminPanelsProvider, (_, _) {});
      final ctrl = c.read(adminPanelsProvider.notifier);
      AdminPanelsState st() => c.read(adminPanelsProvider);

      // start opening
      final opening = ctrl.open('reason');

      // pump until status has started
      int attempts = 0;
      while (!repo.statusStarted && attempts < 5) {
        await Future<void>.delayed(Duration.zero);
        attempts++;
      }
      expect(
        repo.statusStarted,
        isTrue,
        reason: 'status should have started after unlock',
      );

      // background the app
      ctrl.setForeground(false);
      final locked = ctrl.lock();
      expect(
        locked,
        isTrue,
        reason: 'the unlock already returned, so lock must not be skipped',
      );

      // finish status
      repo.statusGate.complete();
      await opening;

      // after status completes, panels should be locked
      expect(st().gate, AdminGate.checking);
      expect(st().hasSnapshot, isFalse);
    },
  );

  test(
    'a lock during the snapshot load after status leaves nothing in memory',
    () async {
      final repo = FakeAdminRepository(); // default status is linked epoch 1
      final unlock = FakeAdminUnlock(); // unlock succeeds immediately
      final store = SlowSnapshotStore();
      store.saved = AdminSavedSnapshot(
        epoch: 1,
        lastId: 3,
        snapshot: AdminSnapshot.empty,
      );

      final c = ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(unlock),
          adminSnapshotStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      // listen to provider to trigger state changes
      c.listen(adminPanelsProvider, (_, _) {});
      final ctrl = c.read(adminPanelsProvider.notifier);
      AdminPanelsState st() => c.read(adminPanelsProvider);

      // start opening
      final opening = ctrl.open('reason');

      // pump until load has started
      int attempts = 0;
      while (!store.loadStarted && attempts < 10) {
        await Future<void>.delayed(Duration.zero);
        attempts++;
      }
      expect(store.loadStarted, isTrue);

      // background the app
      ctrl.setForeground(false);
      expect(ctrl.lock(), isTrue);
      // complete the load gate to allow load to finish
      store.loadGate.complete();
      await opening;

      // after load completes, panels should be locked and snapshot not loaded
      expect(st().gate, AdminGate.checking);
      expect(
        st().hasSnapshot,
        isFalse,
        reason: 'the snapshot must not be loaded into memory after the lock',
      );
    },
  );
}

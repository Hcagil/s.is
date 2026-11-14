// test/features/admin_panels/application/admin_panels_lock_hold_test.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

import 'admin_fakes.dart';

/// A repository that delays the completion of [fetch] until
/// [gate] is completed. It records whether the fetch call
/// has started in [started].
class _GatedFetchRepo extends FakeAdminRepository {
  final Completer<void> gate = Completer<void>();
  bool started = false;

  @override
  Future<Result<List<AdminRow>>> fetch(int afterId) async {
    started = true;
    await gate.future;
    return super.fetch(afterId);
  }
}

/// A repository that delays the completion of [saveLastDownSeq]
/// until [gate] is completed. It records whether the call
/// has started in [started].
class _GatedSaveSeqRepo extends FakeAdminRepository {
  final Completer<void> gate = Completer<void>();
  bool started = false;

  @override
  Future<void> saveLastDownSeq(int epoch, int seq) async {
    started = true;
    await gate.future;
    return super.saveLastDownSeq(epoch, seq);
  }
}

/// A repository that delays the completion of [lastDownSeq]
/// until [gate] is completed. It records whether the call
/// has started in [started].
class _GatedLastSeqRepo extends FakeAdminRepository {
  final Completer<void> gate = Completer<void>();
  bool started = false;

  @override
  Future<int> lastDownSeq(int epoch) async {
    started = true;
    await gate.future;
    return super.lastDownSeq(epoch);
  }
}

/// A seen store that delays the completion of [load]
/// until [gate] is completed. It records whether the call
/// has started in [started].
class _GatedSeenStore extends FakeAdminSeenStore {
  final Completer<void> gate = Completer<void>();
  bool started = false;

  @override
  Future<Map<String, Set<String>>?> load() async {
    started = true;
    await gate.future;
    return super.load();
  }
}

/// Helper that waits until [done] returns true or times out.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 50; i++) {
    if (done()) return;
    await pumpEventQueue();
  }
  fail('until timed out');
}

/// Helper that pumps the event queue a few times.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await pumpEventQueue();
  }
}

/// Helper that asserts the state is empty.
void expectEmpty(AdminPanelsState s) {
  expect(s.hasSnapshot, isFalse);
  expect(s.snapshot.questions, isEmpty);
  expect(s.failure, isNull);
  expect(s.seen, isNull);
  expect(s.syncing, isFalse);
}

void main() {
  test('fetch held then lock', () async {
    final repo = _GatedFetchRepo();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = FakeAdminSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);
    AdminPanelsState st() => c.read(adminPanelsProvider);

    final opening = ctrl.open('r');
    await until(() => repo.started);
    ctrl.lock();
    repo.gate.complete();
    await opening;
    await settle();
    expectEmpty(st());
    expect(store.saveCalls, 0);
    expect(seen.saveCalls, 0);
  });

  test('CONTROL: fetch held then open without lock', () async {
    final repo = _GatedFetchRepo();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = FakeAdminSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);
    AdminPanelsState st() => c.read(adminPanelsProvider);

    final opening = ctrl.open('r');
    await until(() => repo.started);
    repo.gate.complete();
    await opening;
    await settle();
    expect(st().hasSnapshot, isTrue);
    expect(st().snapshot.questions.length, 1);
  });

  test('saveLastDownSeq held then lock: the state stays empty', () async {
    final repo = _GatedSaveSeqRepo();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = FakeAdminSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);
    AdminPanelsState st() => c.read(adminPanelsProvider);

    final opening = ctrl.open('r');
    await until(() => repo.started);
    ctrl.lock();
    repo.gate.complete();
    await opening;
    await settle();
    expectEmpty(st());
    expect(seen.saveCalls, 0);
  });

  test('saveLastDownSeq held then lock: the snapshot is not written to the store after the lock', () async {
    final repo = _GatedSaveSeqRepo();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = FakeAdminSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);

    final opening = ctrl.open('r');
    await until(() => repo.started);
    ctrl.lock();
    repo.gate.complete();
    await opening;
    await settle();
    expect(
      store.saveCalls,
      0,
      reason: 'a decrypted snapshot must not be saved after lock()',
    );
  });

  test('seen-store load held then lock', () async {
    final repo = FakeAdminRepository();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = _GatedSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);
    AdminPanelsState st() => c.read(adminPanelsProvider);

    final opening = ctrl.open('r');
    await until(() => seen.started);
    ctrl.lock();
    seen.gate.complete();
    await opening;
    await settle();
    expectEmpty(st());
    expect(seen.saveCalls, 0);
  });

  test('gap rows then lock (no resync after lock)', () async {
    final repo = _GatedFetchRepo();
    repo.fetchQueue = [
      [
        deltaRow(1, 5, cursor: 9, items: [qItem('Q-9')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = FakeAdminSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);
    AdminPanelsState st() => c.read(adminPanelsProvider);

    final opening = ctrl.open('r');
    await until(() => repo.started);
    ctrl.lock();
    repo.gate.complete();
    await opening;
    await settle();
    expect(repo.sent.isEmpty, isTrue);
    expectEmpty(st());
  });

  // ---------- New tests ----------
  test('lastDownSeq held then lock: the state stays empty', () async {
    final repo = _GatedLastSeqRepo();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = FakeAdminSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);
    AdminPanelsState st() => c.read(adminPanelsProvider);

    final opening = ctrl.open('r');
    await until(() => repo.started);
    ctrl.lock();
    repo.gate.complete();
    await opening;
    await settle();
    expectEmpty(st());
    expect(store.saveCalls, 0);
    expect(seen.saveCalls, 0);
    expect(repo.downSeq.isEmpty, isTrue);
  });

  test(
    'snapshot then a gap, seen load held, then lock: no resync is sent',
    () async {
      final repo = FakeAdminRepository();
      repo.fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
          deltaRow(2, 5, cursor: 9, items: [qItem('Q-2')]),
        ],
      ];
      final unlock = FakeAdminUnlock();
      final store = FakeAdminSnapshotStore();
      final seen = _GatedSeenStore();

      final c = ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(unlock),
          adminSnapshotStoreProvider.overrideWithValue(store),
          adminSeenStoreProvider.overrideWithValue(seen),
        ],
      );
      addTearDown(c.dispose);
      c.listen(adminPanelsProvider, (_, _) {});
      final ctrl = c.read(adminPanelsProvider.notifier);
      AdminPanelsState st() => c.read(adminPanelsProvider);

      final opening = ctrl.open('r');
      await until(() => seen.started);
      ctrl.lock();
      seen.gate.complete();
      await opening;
      await settle();
      expect(repo.sent.isEmpty, isTrue);
      expectEmpty(st());
    },
  );

  test('CONTROL: snapshot then a gap without lock sends one resync', () async {
    final repo = FakeAdminRepository();
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
        deltaRow(2, 5, cursor: 9, items: [qItem('Q-2')]),
      ],
    ];
    final unlock = FakeAdminUnlock();
    final store = FakeAdminSnapshotStore();
    final seen = _GatedSeenStore();

    final c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seen),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    final ctrl = c.read(adminPanelsProvider.notifier);

    final opening = ctrl.open('r');
    await until(() => seen.started);
    seen.gate.complete();
    await opening;
    await settle();
    expect(repo.sent.length, 1);
  });
}

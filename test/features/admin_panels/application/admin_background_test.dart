import 'package:sis/core/failure.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late FakeAdminSeenStore seen;
  late ProviderContainer c;
  late AdminPanelsController ctrl;

  AdminPanelsState st() => c.read(adminPanelsProvider);

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    seen = FakeAdminSeenStore()
      ..saved = {
        'talk': <String>{},
        'questions': <String>{},
        'tasks': <String>{},
      };
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

  test('1 startBackground fetches at once and fills the snapshot without the unlock', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [qItem('Q-1')]),
      ],
    ];
    ctrl.startBackground();
    // allow any microtasks to run
    await pumpEventQueue();
    await pumpEventQueue();
    expect(st().hasSnapshot, isTrue);
    expect(st().snapshot.questions.length, 1);
    expect(st().gate, AdminGate.checking);
    expect(unlock.calls, 0);
  });

  test('2 poll interval is 5 seconds', () {
    fakeAsync((async) {
      ctrl.startBackground();
      async.flushMicrotasks();
      final base = repo.fetchCalls.length;
      async.elapse(const Duration(seconds: 4));
      expect(repo.fetchCalls.length, base);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(repo.fetchCalls.length, base + 1);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(repo.fetchCalls.length, base + 2);
      c.dispose();
    });
  });

  test('3 stopBackground stops the poll', () {
    fakeAsync((async) {
      ctrl.startBackground();
      async.flushMicrotasks();
      ctrl.stopBackground();
      final count = repo.fetchCalls.length;
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(repo.fetchCalls.length, count);
      c.dispose();
    });
  });

  test('4 lock stops the poll and clears the snapshot', () {
    fakeAsync((async) {
      repo.fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
      ctrl.startBackground();
      async.flushMicrotasks();
      expect(st().hasSnapshot, isTrue);
      ctrl.lock();
      expect(st().hasSnapshot, isFalse);
      final count = repo.fetchCalls.length;
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(repo.fetchCalls.length, count);
      c.dispose();
    });
  });

  test('5 an unlinked status in the background does not change the gate', () {
    fakeAsync((async) {
      repo.statusResult = const Ok(
        AdminStatus(AdminLinkPhase.unlinked, epoch: 0),
      );
      ctrl.startBackground();
      async.flushMicrotasks();
      expect(st().gate, AdminGate.checking);
      expect(st().hasSnapshot, isFalse);
      c.dispose();
    });
  });

  test('6 a gap in background rows asks a resync', () {
    fakeAsync((async) {
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
          deltaRow(2, 3, cursor: 6, items: [qItem('Q-3')]),
        ],
      ];
      ctrl.startBackground();
      async.flushMicrotasks();
      expect(repo.sent.length, 1);
      expect(repo.sent.first['kind'], 'resync');
      expect(st().snapshot.questions.length, 1);
      expect(st().snapshot.questions.first.id, 'Q-1');
      c.dispose();
    });
  });

  test('7 startBackground twice does not double the poll', () {
    fakeAsync((async) {
      ctrl.startBackground();
      ctrl.startBackground();
      async.flushMicrotasks();
      final base = repo.fetchCalls.length;
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(repo.fetchCalls.length, base + 1);
      c.dispose();
    });
  });

  test('8 no fetch without startBackground', () async {
    await pumpEventQueue();
    await pumpEventQueue();
    expect(repo.fetchCalls, isEmpty);
    expect(repo.statusCalls, 0);
  });

  test('9 newCounts is non-empty from background data before any unlock', () {
    fakeAsync((async) {
      repo.fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1'), qItem('Q-2')]),
        ],
      ];
      ctrl.startBackground();
      async.flushMicrotasks();
      final counts = st().newCounts;
      expect(counts['questions'], 2);
      expect(unlock.calls, 0);
      c.dispose();
    });
  });
}

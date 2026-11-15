import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late FakeAdminSeenStore seenStore;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late DateTime now;

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    seenStore = FakeAdminSeenStore()
      ..saved = {
        'talk': <String>{},
        'questions': <String>{},
        'tasks': <String>{},
      };
    now = DateTime.utc(2026, 1, 1, 12);
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seenStore),
        adminClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  // Helper to advance fake time and clock together
  void sec(FakeAsync a, int n) {
    for (var i = 0; i < n; i++) {
      now = now.add(const Duration(seconds: 1));
      a.elapse(const Duration(seconds: 1));
      a.flushMicrotasks();
    }
  }

  test('before any send the poll is every 5 s', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      // settle initial polling
      sec(a, 30);
      final base = repo.fetchCalls.length;

      // advance 10 s
      sec(a, 10);
      expect(repo.fetchCalls.length, base + 2);
      c.dispose();
    });
  });

  test('after a send, polls every second for 20 s, then every 5 s', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);
      final base = repo.fetchCalls.length;

      // send
      unawaited(ctrl.setConversationPinned('c1', true));
      a.flushMicrotasks();

      // 19 s after send
      sec(a, 19);
      final after19 = repo.fetchCalls.length;
      expect(after19 - base, inInclusiveRange(18, 20));

      // reach 25 s after send
      sec(a, 6);
      final lenAt25 = repo.fetchCalls.length;

      // 15 s more (total 34 s after send)
      sec(a, 15);
      final after34 = repo.fetchCalls.length;
      expect(after34 - lenAt25, 3);
      c.dispose();
    });
  });

  test('a new send inside the window restarts the 20 s', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);

      // first send
      unawaited(ctrl.setConversationPinned('c1', true));
      a.flushMicrotasks();

      // 15 s later
      sec(a, 15);

      // second send
      unawaited(ctrl.setConversationPinned('c1', true));
      a.flushMicrotasks();

      final mid = repo.fetchCalls.length;

      // 19 s after second send
      sec(a, 19);
      final after19 = repo.fetchCalls.length;
      expect(after19 - mid, inInclusiveRange(18, 20));
      c.dispose();
    });
  });

  test('a failed send does not start the fast window', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);
      final base = repo.fetchCalls.length;

      // set send to fail
      repo.sendResult = Err<AdminSentRef?>(const NetworkFailure('x'));
      unawaited(ctrl.setConversationPinned('c1', true));
      a.flushMicrotasks();

      // 10 s after failed send
      sec(a, 10);
      expect(repo.fetchCalls.length, base + 2);
      c.dispose();
    });
  });
}

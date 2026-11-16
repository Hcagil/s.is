import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_push.dart';

import 'admin_fakes.dart';

/// Fake AdminPush: counts listens and cancels, can fail the join.
class FakeAdminPush implements AdminPush {
  int listenCalls = 0;
  int cancels = 0;
  bool failJoin = false;
  late StreamController<void> ctl;

  @override
  Future<Result<Stream<void>>> listen() async {
    listenCalls++;
    if (failJoin) {
      return Err<Stream<void>>(NetworkFailure('x'));
    }
    ctl = StreamController<void>.broadcast(onCancel: () => cancels++);
    return Ok<Stream<void>>(ctl.stream);
  }

  void emit() => ctl.add(null);
}

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late FakeAdminSeenStore seenStore;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late DateTime now;

  late FakeAdminPush fakePush;

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
    fakePush = FakeAdminPush();

    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminSeenStoreProvider.overrideWithValue(seenStore),
        adminClockProvider.overrideWithValue(() => now),
        adminPushProvider.overrideWithValue(fakePush),
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

  test('foreground and ready subscribes once', () {
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
      expect(fakePush.listenCalls, 1);
      c.dispose();
    });
  });

  test('an event refreshes at once', () {
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

      fakePush.emit();
      a.flushMicrotasks();

      expect(repo.fetchCalls.length, greaterThan(base));
      c.dispose();
    });
  });

  test('no subscription in background', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      // never setForeground(true)
      a.flushMicrotasks();
      sec(a, 30);

      expect(fakePush.listenCalls, 0);
      c.dispose();
    });
  });

  test('background cancels', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);
      expect(fakePush.listenCalls, 1);

      ctrl.setForeground(false);
      a.flushMicrotasks();

      expect(fakePush.cancels, 1);

      final base = repo.fetchCalls.length;
      fakePush.emit();
      a.flushMicrotasks();
      expect(repo.fetchCalls.length, base);
      c.dispose();
    });
  });

  test('lock cancels', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);
      expect(fakePush.listenCalls, 1);

      ctrl.lock();
      a.flushMicrotasks();

      expect(fakePush.cancels, 1);
      c.dispose();
    });
  });

  test('dispose cancels', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);
      expect(fakePush.listenCalls, 1);

      c.dispose();
      a.flushMicrotasks();

      expect(fakePush.cancels, 1);
    });
  });

  test('join failure keeps polling', () {
    fakeAsync((a) {
      repo.fetchQueue = [
        [snapRow(1, 1, cursor: 5)],
      ];

      fakePush.failJoin = true;
      unawaited(ctrl.open('reason'));
      a.flushMicrotasks();
      ctrl.setForeground(true);
      a.flushMicrotasks();

      sec(a, 30);
      final base = repo.fetchCalls.length;

      sec(a, 10);
      expect(repo.fetchCalls.length, base + 2);
      c.dispose();
    });
  });
}

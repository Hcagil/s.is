import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;

  Future<void> openIt() => ctrl.open('reason');

  AdminPanelsState st() => c.read(adminPanelsProvider);

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

  test(
    '22023 from the server: the link screen shows and nothing is marked sent',
    () async {
      await openIt();
      expect(st().gate, AdminGate.ready);
      repo.sendResult = const Err(DeniedFailure());
      repo.statusResult = const Ok(AdminStatus(AdminLinkPhase.unlinked));
      final calls = repo.statusCalls;
      final f = await ctrl.answerQuestion('Q-1', 'a');
      expect(f, isA<DeniedFailure>());
      expect(st().gate, AdminGate.link);
      expect(st().link?.phase, AdminLinkPhase.unlinked);
      expect(repo.statusCalls, greaterThan(calls));
      expect(st().sentQuestions, isEmpty);
    },
  );

  test('lock drops everything held in memory', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    expect(st().hasSnapshot, isTrue);
    expect(ctrl.lock(), isTrue);
    expect(st().gate, AdminGate.checking);
    expect(st().hasSnapshot, isFalse);
    expect((st().snapshot.toJson()['items'] as List).isEmpty, isTrue);
    await openIt();
    expect(unlock.calls, 2);
    expect(st().gate, AdminGate.ready);
  });

  test('lock returns false while the unlock is running', () async {
    unlock.hold = Completer<AdminUnlockResult>();
    final f = openIt();
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.lock(), isFalse);
    expect(st().gate, AdminGate.checking);
    unlock.hold!.complete(AdminUnlockResult.ok);
    await f;
    expect(st().gate, AdminGate.ready);
  });

  test('no fetch runs while the screen is closed or in the background', () {
    fakeAsync((async) {
      final container = ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(unlock),
          adminSnapshotStoreProvider.overrideWithValue(store),
        ],
      );
      final sub = container.listen(adminPanelsProvider, (_, _) {});
      final ctrl2 = container.read(adminPanelsProvider.notifier);
      unawaited(ctrl2.open('r'));
      async.flushMicrotasks();
      final base = repo.fetchCalls.length;
      async.elapse(const Duration(minutes: 3));
      expect(repo.fetchCalls.length, base);
      ctrl2.setForeground(true);
      async.elapse(const Duration(seconds: 45));
      expect(repo.fetchCalls.length, greaterThan(base));
      ctrl2.setForeground(false);
      async.flushMicrotasks();
      final stopped = repo.fetchCalls.length;
      async.elapse(const Duration(minutes: 3));
      expect(repo.fetchCalls.length, stopped);
      ctrl2.setForeground(true);
      sub.close();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      final closedAt = repo.fetchCalls.length;
      async.elapse(const Duration(minutes: 3));
      expect(repo.fetchCalls.length, closedAt);
      container.dispose();
    });
  });
}

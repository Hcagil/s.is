import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import 'admin_fakes.dart';

class HoldSendRepo extends FakeAdminRepository {
  Completer<Result<AdminSentRef?>>? sendHold;
  @override
  Future<Result<AdminSentRef?>> send(Map<String, Object?> message) {
    final h = sendHold;
    if (h != null) {
      sent.add(message);
      return h.future;
    }
    return super.send(message);
  }
}

void main() {
  late HoldSendRepo repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late FakeAdminSeenStore seenStore;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late DateTime now;

  AdminPanelsState st() => c.read(adminPanelsProvider);

  setUp(() {
    repo = HoldSendRepo();
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

  // Helper to create a conversation item
  AdminItem convItem(String id, {int seen = 0, int mat = 0}) => AdminItem(
    id: 'c:$id',
    kind: 'talk',
    seq: 1,
    removed: false,
    fields: {
      'id': id,
      'topic': 'T',
      'at': 1000,
      'unread': false,
      'waiting': 0,
      'conv': true,
      'seen': seen,
      'mat': mat,
    },
  );

  test('a failed mark is re-sent on the next poll tick until it succeeds', () {
    fakeAsync((async) {
      // Initial fetch with one conversation
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 5, items: [convItem('c1', mat: 20)]),
        ],
      ];

      // Open controller and flush initial microtasks
      unawaited(ctrl.open('reason'));
      async.flushMicrotasks();
      ctrl.setForeground(true);
      async.flushMicrotasks();

      // Get the conversation
      final conv = st().snapshot.conversations.first;

      // Simulate a failed send
      repo.sendResult = Err<AdminSentRef?>(const NetworkFailure('boom'));
      unawaited(ctrl.markConversationRead(conv, 5));
      async.flushMicrotasks();

      // After first mark, one send attempt should have been made
      expect(repo.sent.length, 1);
      expect(st().readUpto['c1'], 5);

      // Helper to advance time and trigger poll
      void tick() {
        now = now.add(const Duration(seconds: 6));
        async.elapse(adminPollEvery);
        async.flushMicrotasks();
      }

      // First tick: should retry
      tick();
      expect(repo.sent.length, 2);
      expect(repo.sent.last['upto'], 5);
      expect(repo.sent.last['conv'], 'c1');
      expect(st().readUpto['c1'], 5);

      // Simulate success on next send
      repo.sendResult = null;
      tick();
      expect(repo.sent.length, 3);

      // Subsequent tick: no further sends
      tick();
      expect(repo.sent.length, 3);

      c.dispose();
    });
  });
}

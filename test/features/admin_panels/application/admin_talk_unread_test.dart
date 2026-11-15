import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('talk count is the number of unread conversations', () async {
    repo.fetchQueue = [
      [
        snapRow(
          1,
          1,
          cursor: 5,
          items: [
            convItem('c1', seen: 0, mat: 5),
            convItem('c2', seen: 7, mat: 7),
            convItem('c3', seen: 3, mat: 9),
          ],
        ),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
    expect(st().newCounts['talk'], 2);
  });

  test('reading every conversation gives no number', () async {
    repo.fetchQueue = [
      [
        snapRow(
          1,
          1,
          cursor: 5,
          items: [
            convItem('c1', seen: 0, mat: 5),
            convItem('c2', seen: 7, mat: 7),
            convItem('c3', seen: 3, mat: 9),
          ],
        ),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
    final conv1 = st().snapshot.conversations.firstWhere((c) => c.id == 'c1');
    final conv3 = st().snapshot.conversations.firstWhere((c) => c.id == 'c3');
    await ctrl.markConversationRead(conv1, 5);
    await ctrl.markConversationRead(conv3, 9);
    expect(st().newCounts['talk'] ?? 0, 0);
  });

  test('a read shows at once while the send is still running', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [convItem('c1', seen: 0, mat: 5)]),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
    final conv = st().snapshot.conversations.first;
    repo.sendHold = Completer();
    final f = ctrl.markConversationRead(conv, 5);
    await pumpEventQueue();
    expect(st().readUpto['c1'], 5);
    expect(st().newCounts['talk'] ?? 0, 0);
    repo.sendHold!.complete(Ok(AdminSentRef(1, 1)));
    await f;
  });

  test('reconnect fetches at once', () async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [convItem('c1', seen: 0, mat: 5)]),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
    final before = repo.fetchCalls.length;
    await ctrl.reconnect();
    expect(repo.fetchCalls.length, before + 1);
  });
}

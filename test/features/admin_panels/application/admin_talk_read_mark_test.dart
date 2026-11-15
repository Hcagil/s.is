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

  test('an older or duplicate mark sends nothing', () async {
    repo.fetchQueue = [
      [
        snapRow(
          1,
          1,
          cursor: 5,
          items: [
            convItem('c1', seen: 0, mat: 20),
            convItem('c2', seen: 20, mat: 20),
          ],
        ),
      ],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();

    final conv1 = st().snapshot.conversations.firstWhere((x) => x.id == 'c1');
    final conv2 = st().snapshot.conversations.firstWhere((x) => x.id == 'c2');

    await ctrl.markConversationRead(conv1, 20);
    expect(repo.sent.length, 1);

    await ctrl.markConversationRead(conv1, 20);
    await ctrl.markConversationRead(conv1, 10);
    expect(repo.sent.length, 1); // duplicate and older send nothing

    await ctrl.markConversationRead(conv2, 20);
    expect(repo.sent.length, 1); // computer's seen already covers it

    await ctrl.markConversationRead(conv1, 25);
    expect(repo.sent.length, 2);
    expect(repo.sent.last['upto'], 25);
  });
}

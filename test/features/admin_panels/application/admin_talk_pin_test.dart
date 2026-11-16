import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import 'admin_fakes.dart';

/// Helper to create a conversation item
AdminItem convItem(String id, {int pinnedAt = 0}) => AdminItem(
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
    if (pinnedAt > 0) 'pinned_at': pinnedAt,
  },
);

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late FakeAdminSeenStore seenStore;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late DateTime now;

  AdminPanelsState st() => c.read(adminPanelsProvider);

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

  Future<void> loadSnapshot(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
  }

  Future<void> loadDelta(
    List<AdminItem> items, {
    List<AdminAnswerResult>? results,
  }) async {
    repo.fetchQueue = [
      [
        deltaRow(
          2,
          2,
          cursor: 6,
          items: items,
          results: results ?? const <AdminAnswerResult>[],
        ),
      ],
    ];
    await ctrl.refresh();
  }

  test('pinned first, earliest pinned first', () async {
    await loadSnapshot([
      convItem('c1'),
      convItem('c2', pinnedAt: 300),
      convItem('c3'),
      convItem('c4', pinnedAt: 100),
      convItem('c5', pinnedAt: 200),
    ]);
    final order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c4', 'c5', 'c2', 'c1', 'c3']);
  });

  test('ties keep snapshot order', () async {
    await loadSnapshot([
      convItem('c1', pinnedAt: 100),
      convItem('c2', pinnedAt: 100),
      convItem('c3', pinnedAt: 100),
    ]);
    var order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c1', 'c2', 'c3']);
  });

  test('ties keep snapshot order (reversed)', () async {
    await loadSnapshot([
      convItem('c3', pinnedAt: 100),
      convItem('c2', pinnedAt: 100),
      convItem('c1', pinnedAt: 100),
    ]);
    var order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c3', 'c2', 'c1']);
  });

  test('no pins keeps snapshot order', () async {
    await loadSnapshot([convItem('c1'), convItem('c2'), convItem('c3')]);
    final order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c1', 'c2', 'c3']);
  });

  test('optimistic pin sits at the END of the pinned block', () async {
    await loadSnapshot([
      convItem('c1'),
      convItem('c2', pinnedAt: 100),
      convItem('c3'),
      convItem('c4', pinnedAt: 500),
    ]);
    await ctrl.setConversationPinned('c3', true);
    var order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c2', 'c4', 'c3', 'c1']);

    await ctrl.setConversationPinned('c1', true);
    order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c2', 'c4', 'c1', 'c3']);
  });

  test('unpinning optimistically moves it out', () async {
    await loadSnapshot([
      convItem('c1'),
      convItem('c2', pinnedAt: 100),
      convItem('c3'),
    ]);
    await ctrl.setConversationPinned('c2', false);
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c2'),
      ),
      false,
    );
    final order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c1', 'c2', 'c3']);
  });

  test('pin sends the up-note', () async {
    await loadSnapshot([convItem('c3')]);
    final result = await ctrl.setConversationPinned('c3', true);
    expect(result, null);
    final last = repo.sent.last;
    expect(last['kind'], 'pin');
    expect(last['conv'], 'c3');
    expect(last['pinned'], true);
    expect(last.containsKey('answer_id'), true);
  });

  test('send failure reverts', () async {
    await loadSnapshot([convItem('c3')]);
    repo.sendResult = Err<AdminSentRef?>(const NetworkFailure('x'));
    final result = await ctrl.setConversationPinned('c3', true);
    expect(result, isNotNull);
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c3'),
      ),
      false,
    );
    expect(st().pinOverride.containsKey('c3'), false);
  });

  test('computer rejection (ok:false) reverts, no failure returned', () async {
    await loadSnapshot([convItem('c3')]);
    await ctrl.setConversationPinned('c3', true);
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c3'),
      ),
      true,
    );
    await loadDelta(
      [],
      results: [AdminAnswerResult(epoch: 1, upSeq: 1, ok: false)],
    );
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c3'),
      ),
      false,
    );
  });

  test('snapshot showing the same state drops the optimistic state', () async {
    await loadSnapshot([convItem('c3')]);
    await ctrl.setConversationPinned('c3', true);
    expect(st().pinOverride.containsKey('c3'), true);
    await loadDelta([convItem('c3', pinnedAt: 700)]);
    expect(st().pinOverride.containsKey('c3'), false);
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c3'),
      ),
      true,
    );
    final order = st().talkOrder.map((c) => c.id).toList();
    expect(order, ['c3']);
  });

  test('ok:true result keeps pinned while snapshot not yet updated', () async {
    await loadSnapshot([convItem('c3')]);
    await ctrl.setConversationPinned('c3', true);
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c3'),
      ),
      true,
    );
    await loadDelta(
      [],
      results: [AdminAnswerResult(epoch: 1, upSeq: 1, ok: true)],
    );
    expect(
      st().isPinned(
        st().snapshot.conversations.firstWhere((c) => c.id == 'c3'),
      ),
      true,
    );
  });
}

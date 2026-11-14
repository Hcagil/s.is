import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot_store.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

import '../../../support/spy_admin_draft_store.dart';
import './admin_fakes.dart';

/// Conversation item helper used by the tests.
AdminItem convItem(String id) => AdminItem(
  id: 'c:$id',
  kind: 'talk',
  seq: 1,
  removed: false,
  fields: {
    'id': id,
    'topic': 'Topic',
    'at': 1000,
    'unread': false,
    'waiting': 0,
    'conv': true,
  },
);

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late AdminDrafts draftsCtrl;

  Future<void> openIt() => ctrl.open('reason');

  AdminPanelsState st() => c.read(adminPanelsProvider);

  Future<void> settle() async {
    await pumpEventQueue();
    await c.read(adminDraftsProvider).flush();
    await pumpEventQueue();
  }

  /// Builds a container with the given draft store override.
  void boot(SpyAdminDraftStore spy) {
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminDraftStoreProvider.overrideWithValue(spy),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
    draftsCtrl = c.read(adminDraftsProvider);
  }

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
  });

  test('prune after a complete snapshot', () async {
    final spy = SpyAdminDraftStore({
      'q:Q-1': 'a',
      'q:Q-gone': 'b',
      'talk:c1': 'c',
      'talk:cgone': 'd',
      'talk:new': 'e',
    });
    boot(spy);
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1'), convItem('c1')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    await settle();
    expect(spy.saved.keys.toSet(), {'q:Q-1', 'talk:c1', 'talk:new'});
  });

  test('a cached snapshot never prunes', () async {
    store.saved = AdminSavedSnapshot(
      epoch: 1,
      lastId: 9,
      snapshot: AdminSnapshot.full([qItem('Q-5')], cursor: 4, truncated: false),
    );
    final spy = SpyAdminDraftStore({'q:Q-9': 'x'});
    boot(spy);
    await openIt();
    expect(st().hasSnapshot, isTrue);
    await settle();
    expect(spy.saved, {'q:Q-9': 'x'});
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 6, items: [qItem('Q-5')]),
      ],
    ];
    await ctrl.refresh();
    await settle();
    expect(spy.saved, isEmpty);
  });

  test('a delta does not prune', () async {
    final spy = SpyAdminDraftStore({'q:Q-7': 'keep'});
    boot(spy);
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-7')]),
      ],
    ];
    await openIt();
    await ctrl.refresh();
    repo.fetchQueue = [
      [
        deltaRow(2, 2, cursor: 7, items: [qItem('Q-8')]),
      ],
    ];
    await ctrl.refresh();
    await settle();
    expect(spy.saved, {'q:Q-7': 'keep'});
  });

  test('nothing is read before unlock', () async {
    final spy = SpyAdminDraftStore({'q:Q-1': 'a'});
    unlock.result = AdminUnlockResult.cancelled;
    boot(spy);
    await openIt();
    await settle();
    expect(spy.loads, 0);
    // before any open
    expect(spy.loads, 0);
  });

  test('lock flushes and drops memory', () async {
    final spy = SpyAdminDraftStore();
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [qItem('Q-1')]),
      ],
    ];
    boot(spy);
    await openIt();
    await ctrl.refresh();
    await pumpEventQueue();
    await draftsCtrl.write('q:Q-1', 'typed');
    expect(spy.saved, isEmpty);
    expect(ctrl.lock(), isTrue);
    await pumpEventQueue();
    expect(spy.saved, {'q:Q-1': 'typed'});
    spy.saved = {'q:Q-1': 'changed on disk'};
    expect(await draftsCtrl.read('q:Q-1'), 'changed on disk');
  });
}

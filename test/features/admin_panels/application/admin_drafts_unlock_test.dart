import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_draft_store.dart';

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

/// Simple in‑memory store that can delay the first load.
class _HoldStore implements AdminDraftStore {
  Map<String, String> saved;
  final List<Map<String, String>> saveLog = [];
  final Completer<Map<String, String>> firstLoad = Completer();
  bool first = true;

  _HoldStore() : saved = {};

  @override
  Future<Map<String, String>> load() async {
    if (first) {
      first = false;
      return firstLoad.future;
    }
    return Map.of(saved);
  }

  @override
  Future<void> save(Map<String, String> m) async {
    saveLog.add(Map.of(m));
    saved = Map.of(m);
  }

  @override
  Future<void> clear() async {
    saved = {};
  }
}

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;

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
  }

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
  });

  /* ---------- Group 1: controller behaviour ---------- */

  test('T1 startBackground with a snapshot never loads drafts', () async {
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
    ctrl.startBackground();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(st().gate, AdminGate.checking);
    expect(st().snapshot.questions.length, 1);
    expect(spy.loads, 0);
    expect(spy.saves, 0);
    expect(spy.saved, {
      'q:Q-1': 'a',
      'q:Q-gone': 'b',
      'talk:c1': 'c',
      'talk:cgone': 'd',
      'talk:new': 'e',
    });
  });

  test('T2 refresh before any open never loads drafts', () async {
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
    await ctrl.refresh();
    await pumpEventQueue();
    expect(st().gate, AdminGate.checking);
    expect(st().snapshot.questions.length, 1);
    expect(spy.loads, 0);
    expect(spy.saves, 0);
    expect(spy.saved, {
      'q:Q-1': 'a',
      'q:Q-gone': 'b',
      'talk:c1': 'c',
      'talk:cgone': 'd',
      'talk:new': 'e',
    });
  });

  test(
    'T3 after the unlock, dead drafts are pruned and kept ones stay',
    () async {
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
    },
  );

  /* ---------- Group 2: AdminDrafts directly ---------- */

  test(
    'T4 wipe while a load is in flight does not bring the old drafts back',
    () async {
      final store = _HoldStore()..saved = {'q:1': 'old', 'q:2': 'gone'};
      final d = AdminDrafts(store);
      final pruning = d.prune('q:', <String>{'1'});
      // do not await pruning
      await d.wipe();
      store.firstLoad.complete({'q:1': 'old', 'q:2': 'gone'});
      await pruning;
      await d.flush();
      await Future<void>.delayed(
        adminDraftDebounce + const Duration(milliseconds: 100),
      );
      expect(store.saveLog.any((m) => m.containsKey('q:1')), isFalse);
      expect(store.saved, isEmpty);
      expect(await d.read('q:1'), '');
      d.dispose();
    },
  );

  test(
    'T5 forget while a load is in flight writes nothing afterwards',
    () async {
      final store = _HoldStore()..saved = {'q:1': 'old', 'q:2': 'gone'};
      final d = AdminDrafts(store);
      final pruning = d.prune('q:', <String>{'1'});
      await d.forget();
      store.firstLoad.complete({'q:1': 'old', 'q:2': 'gone'});
      await pruning;
      await Future<void>.delayed(
        adminDraftDebounce + const Duration(milliseconds: 100),
      );
      expect(store.saveLog, isEmpty);
      d.dispose();
    },
  );

  test('T6 prune finished after forget schedules no save', () async {
    final store = _HoldStore()..saved = {'q:2': 'gone'};
    final d = AdminDrafts(store);
    final pruning = d.prune('q:', <String>{});
    // not awaited; first load is held
    await d.forget(); // cache is null, so no save
    expect(
      await d.read('q:2'),
      'gone',
    ); // second load (not held) fills the cache from store.saved
    store.firstLoad.complete({'q:2': 'gone'});
    await pruning;
    await Future<void>.delayed(
      adminDraftDebounce + const Duration(milliseconds: 100),
    );
    expect(store.saveLog, isEmpty);
    d.dispose();
  });

  test('T7 write finished after wipe schedules no save', () async {
    final store = _HoldStore()..saved = {'q:2': 'gone'};
    final d = AdminDrafts(store);
    final writing = d.write('q:9', 'late');
    await d.wipe(); // wipe clears the store (store.saved becomes {})
    // after wipe, set store.saved = {'q:2': 'gone'} again
    store.saved = {'q:2': 'gone'};
    expect(await d.read('q:2'), 'gone');
    store.firstLoad.complete({'q:2': 'gone'});
    await writing;
    await Future<void>.delayed(
      adminDraftDebounce + const Duration(milliseconds: 100),
    );
    expect(store.saveLog, isEmpty);
    d.dispose();
  });
}

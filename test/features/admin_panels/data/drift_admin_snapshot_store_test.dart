import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/data/drift_admin_snapshot_store.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import '../../chat/data/store/store_harness.dart';

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  DriftMessageStore messages([String owner = 'owner-1']) =>
      h.open(owner: owner, key: key);

  List<String> ids(AdminSnapshot s) => [
    for (final i in s.toJson()['items'] as List) (i as Map)['id'] as String,
  ];

  AdminItem item1 = AdminItem(
    id: 'q:1',
    kind: 'question',
    seq: 1,
    removed: false,
    fields: {'a': 1},
  );
  AdminItem item2 = AdminItem(
    id: 'q:2',
    kind: 'question',
    seq: 2,
    removed: false,
    fields: {'b': 2},
  );

  AdminSavedSnapshot saved(
    int epoch,
    int lastId,
    List<AdminItem> items, {
    int cursor = 7,
    bool truncated = false,
  }) => AdminSavedSnapshot(
    epoch: epoch,
    lastId: lastId,
    snapshot: AdminSnapshot.full(items, cursor: cursor, truncated: truncated),
  );

  test('nothing saved: load is null', () async {
    final store = DriftAdminSnapshotStore(messages());
    expect(await store.load(), isNull);
  });

  test('save then load', () async {
    final store = DriftAdminSnapshotStore(messages());
    await store.save(saved(1, 10, [item1, item2], truncated: true));
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.epoch, 1);
    expect(loaded.lastId, 10);
    expect(loaded.snapshot.cursor, 7);
    expect(loaded.snapshot.truncated, true);
    expect(ids(loaded.snapshot), ['q:1', 'q:2']);
    expect(((loaded.snapshot.toJson()['items'] as List)[0] as Map)['fields'], {
      'a': 1,
    });

    // reopen
    final reopened = DriftAdminSnapshotStore(messages());
    final loaded2 = await reopened.load();
    expect(loaded2, isNotNull);
    expect(loaded2!.epoch, 1);
    expect(loaded2.lastId, 10);
    expect(ids(loaded2.snapshot), ['q:1', 'q:2']);
  });

  test('second save replaces the first', () async {
    final store = DriftAdminSnapshotStore(messages());
    await store.save(saved(1, 10, [item1, item2]));
    await store.save(saved(2, 20, [item1]));
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.epoch, 2);
    expect(loaded.lastId, 20);
    expect(ids(loaded.snapshot), ['q:1']);
  });

  test('clear then load is null', () async {
    final store = DriftAdminSnapshotStore(messages());
    await store.save(saved(1, 10, [item1, item2]));
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('sign-out wipe', () async {
    final store = DriftAdminSnapshotStore(messages());
    await store.save(saved(1, 10, [item1, item2]));
    final m = messages();
    await m.clear(); // sign-out
    final reopened = DriftAdminSnapshotStore(messages());
    expect(await reopened.load(), isNull);
  });

  test('corrupt data', () async {
    final store = DriftAdminSnapshotStore(messages());
    await store.save(saved(1, 10, [item1, item2]));
    final m = messages();
    final n = await m.run<int>(
      0,
      (db) => db.customUpdate(
        "UPDATE meta SET value = '{\"x\":[' WHERE key = 'admin_snapshot'",
      ),
    );
    expect(n, 1);
    expect(await store.load(), isNull);
    final count = await m.run<int>(-1, (db) async {
      final rows = await db
          .customSelect("SELECT 1 FROM meta WHERE key = 'admin_snapshot'")
          .get();
      return rows.length;
    });
    expect(count, 0);
    // fresh save
    await store.save(saved(2, 20, [item1]));
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.epoch, 2);
  });

  test('wrong shape', () async {
    final store = DriftAdminSnapshotStore(messages());
    await store.save(saved(1, 10, [item1, item2]));
    final m = messages();
    final n = await m.run<int>(
      0,
      (db) => db.customUpdate(
        "UPDATE meta SET value = '{\"epoch\":1,\"lastId\":2,\"snapshot\":\"nope\"}' WHERE key = 'admin_snapshot'",
      ),
    );
    expect(n, 1);
    expect(await store.load(), isNull);
  });

  test('owner-2 store loads null after owner-1 saved', () async {
    final store1 = DriftAdminSnapshotStore(messages());
    await store1.save(saved(1, 10, [item1, item2]));
    final store2 = DriftAdminSnapshotStore(messages('owner-2'));
    expect(await store2.load(), isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/data/drift_admin_seen_store.dart';
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

  test('nothing saved: load is null', () async {
    final store = DriftAdminSeenStore(messages());
    expect(await store.load(), isNull);
  });

  test('save then reopen then load', () async {
    final store = DriftAdminSeenStore(messages());
    await store.save({
      'talk': {'m1', 'm2'},
      'questions': {'q1'},
      'tasks': <String>{},
    });
    final reopened = DriftAdminSeenStore(messages());
    final loaded = await reopened.load();
    expect(loaded, isNotNull);
    expect(loaded, {
      'talk': {'m1', 'm2'},
      'questions': {'q1'},
      'tasks': <String>{},
    });
  });

  test('second save replaces the first', () async {
    final store = DriftAdminSeenStore(messages());
    await store.save({
      'talk': {'a'},
    });
    await store.save({
      'questions': {'b'},
    });
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded, {
      'questions': {'b'},
    });
  });

  test('clear empties', () async {
    final store = DriftAdminSeenStore(messages());
    await store.save({
      'talk': {'a'},
    });
    await store.clear();
    expect(await store.load(), isNull);
    final reopened = DriftAdminSeenStore(messages());
    expect(await reopened.load(), isNull);
  });

  test('corrupt data: load null and row removed', () async {
    final store = DriftAdminSeenStore(messages());
    await store.save({
      'talk': {'a'},
    });
    final m = messages();
    final n = await m.run<int>(
      0,
      (db) => db.customUpdate(
        "UPDATE meta SET value = '{\"x\":[' WHERE key = 'admin_seen'",
      ),
    );
    expect(n, 1);
    expect(await store.load(), isNull);
    final count = await m.run<int>(-1, (db) async {
      final rows = await db
          .customSelect("SELECT 1 FROM meta WHERE key = 'admin_seen'")
          .get();
      return rows.length;
    });
    expect(count, 0);
    // fresh save
    await store.save({
      'talk': {'b'},
    });
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded, {
      'talk': {'b'},
    });
  });

  test('owner-2 store loads null after owner-1 saved', () async {
    final store1 = DriftAdminSeenStore(messages());
    await store1.save({
      'talk': {'a'},
    });
    final store2 = DriftAdminSeenStore(messages('owner-2'));
    expect(await store2.load(), isNull);
  });
}

// reconcile_keep_senders_test.dart
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/message.dart';

import 'store_harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  DriftMessageStore open(Future<Set<String>> Function(Set<String>)? keep) {
    final s = DriftMessageStore(
      ownerId: 'bob',
      file: () async => h.file,
      key: () async => key,
      deleteKey: () async {},
      keepSenders: keep,
    );
    addTearDown(s.close);
    return s;
  }

  Future<void> seed(DriftMessageStore s) async {
    await s.upsertAll([
      msg('a', t: 1, sender: 'uma'),
      msg('v1', t: 2, sender: 'vic'),
      msg('u2', t: 3, sender: 'uma'),
      msg('v2', t: 4, sender: 'vic'),
      msg('b', t: 5, sender: 'wes'),
    ]);
  }

  test(
    'keepSenders {vic}: vic stale rows stay, uma stale row is deleted',
    () async {
      final s = open((Set<String> ids) async => {'vic'});
      await seed(s);
      await s.reconcilePage('c1', [
        msg('a', t: 1, sender: 'uma'),
        msg('b', t: 5, sender: 'wes'),
      ], reachedStart: false);
      expect(ids(await s.newest('c1')), ['a', 'v1', 'v2', 'b']);
    },
  );

  test('keepSenders null: all stale rows deleted', () async {
    final s = open(null);
    await seed(s);
    await s.reconcilePage('c1', [
      msg('a', t: 1, sender: 'uma'),
      msg('b', t: 5, sender: 'wes'),
    ], reachedStart: false);
    expect(ids(await s.newest('c1')), ['a', 'b']);
  });

  test('keepSenders returns empty set: all stale rows deleted', () async {
    final s = open((_) async => {});
    await seed(s);
    await s.reconcilePage('c1', [
      msg('a', t: 1, sender: 'uma'),
      msg('b', t: 5, sender: 'wes'),
    ], reachedStart: false);
    expect(ids(await s.newest('c1')), ['a', 'b']);
  });

  test('keepSenders throws: all stale rows kept', () async {
    final s = open((_) async => throw StateError('offline'));
    await seed(s);
    await s.reconcilePage('c1', [
      msg('a', t: 1, sender: 'uma'),
      msg('b', t: 5, sender: 'wes'),
    ], reachedStart: false);
    expect(ids(await s.newest('c1')), ['a', 'v1', 'u2', 'v2', 'b']);
  });

  test('keepSenders is called once, before the delete, with only the stale senders', () async {
    final calls = <Set<String>>[];
    late DriftMessageStore s;
    final sOpen = open((Set<String> asked) async {
      calls.add(asked);
      // Inspect state before deletion
      final seen = ids(await s.newest('c1'));
      expect(seen, ['a', 'v1', 'u2', 'v2', 'b']);
      return {};
    });
    s = sOpen;
    await seed(s);
    await s.reconcilePage('c1', [
      msg('a', t: 1, sender: 'uma'),
      msg('b', t: 5, sender: 'wes'),
    ], reachedStart: false);
    expect(calls.length, 1);
    expect(calls.first, {'vic', 'uma'});
  });

  test('a row the server now lists as deleted is still updated while its sender is kept', () async {
    final s = open((_) async => {'vic'});
    await s.upsertAll([
      msg('a', t: 1, sender: 'uma'),
      msg('v1', t: 2, sender: 'vic'),
      msg('b', t: 3, sender: 'uma'),
    ]);
    await s.reconcilePage('c1', [
      msg('a', t: 1, sender: 'uma'),
      msg('v1', t: 2, sender: 'vic', deletion: MessageDeletion.placeholder),
      msg('b', t: 3, sender: 'uma'),
    ], reachedStart: false);
    final rows = await s.newest('c1');
    final v1 = rows.firstWhere((m) => m.id == 'v1');
    expect(v1.deletion, MessageDeletion.placeholder);
    expect(rows.length, 3);
  });
}

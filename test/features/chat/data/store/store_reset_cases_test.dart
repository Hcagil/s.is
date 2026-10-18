import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message_store.dart';

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  MessageStore store([String owner = 'owner-1']) =>
      h.open(owner: owner, key: key);

  group('unusable file resets the store', () {
    test('wrong key: old data gone, new saves work, file re-keyed', () async {
      final keyA = key;
      final keyB = await h.newKey();

      // Store old data with key A
      await store().upsertAll([msg('old')]);

      // Open with key B
      key = keyB;
      final sB = store();
      expect(ids(await sB.newest('c1')), isEmpty);

      // Upsert new data with key B
      await sB.upsertAll([msg('new')]);
      expect(ids(await sB.newest('c1')), ['new']);

      // Cold reopen with key B
      final sB2 = store();
      expect(ids(await sB2.newest('c1')), ['new']);

      // Cold reopen with key A should be empty
      key = keyA;
      final sA = store();
      expect(ids(await sA.newest('c1')), isEmpty);
    });

    test('random bytes: resets and works', () async {
      final rnd = Random(7);
      final bytes = List<int>.generate(8192, (_) => rnd.nextInt(256));
      await h.file.writeAsBytes(bytes);

      final s = store();
      expect(ids(await s.newest('c1')), isEmpty);
      expect(await s.cursor(), isNull);

      await s.upsertAll([msg('fresh')]);
      expect(ids(await s.newest('c1')), ['fresh']);

      // Cold reopen
      final s2 = store();
      expect(ids(await s2.newest('c1')), ['fresh']);
    });

    test('truncated file: resets and works', () async {
      final s = store();
      await s.upsertAll([for (var i = 0; i < 200; i++) msg('m$i', t: i)]);

      // Truncate file to half its length
      final raf = await h.file.open(mode: FileMode.writeOnlyAppend);
      final half = h.file.lengthSync() ~/ 2;
      await raf.truncate(half);
      await raf.close();

      // Delete WAL and SHM if they exist
      if (h.wal.existsSync()) h.wal.deleteSync();
      if (h.shm.existsSync()) h.shm.deleteSync();

      // New store should not throw
      await expectLater(
        () async => await store().newest('c1', limit: 500),
        returnsNormally,
      );

      // Upsert fresh data
      await store().upsertAll([msg('fresh', t: 999)]);

      // Cold reopen should contain fresh
      final s2 = store();
      expect(ids(await s2.newest('c1', limit: 500)), contains('fresh'));
    });

    test('damaged header: resets and works', () async {
      final s = store();
      await s.upsertAll([msg('old')]);

      // Overwrite first 100 bytes with zeros
      final raf = await h.file.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(0);
      await raf.writeFrom(List<int>.filled(100, 0));
      await raf.close();

      // Delete WAL and SHM if they exist
      if (h.wal.existsSync()) h.wal.deleteSync();
      if (h.shm.existsSync()) h.shm.deleteSync();

      // New store should be empty
      final s2 = store();
      expect(ids(await s2.newest('c1')), isEmpty);

      // Upsert fresh data
      await s2.upsertAll([msg('fresh')]);
      expect(ids(await s2.newest('c1')), ['fresh']);
    });
  });
}

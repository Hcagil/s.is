// deleteOrphanStores against a real temp folder: set-aside stores
// (sis_store.orphan-*.sqlite, -wal, -shm) go; the live store and any other file stay.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/store_location.dart';

List<String> names(Directory d) =>
    (d.listSync().map((e) => p.basename(e.path)).toList()..sort());

void main() {
  test('deletes orphan sets and preserves live store files', () async {
    final dir = await Directory.systemTemp.createTemp('sis-orphans-');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Live store files
    final liveBase = p.join(dir.path, 'sis_store.sqlite');
    final liveFiles = [
      File(liveBase),
      File('$liveBase-wal'),
      File('$liveBase-shm'),
    ];
    for (final f in liveFiles) {
      f.writeAsBytesSync([1, 2, 3]);
    }

    // Orphan sets
    final stamps = ['1761000000', '1761000500'];
    for (final stamp in stamps) {
      final base = p.join(dir.path, 'sis_store.orphan-$stamp.sqlite');
      final files = [File(base), File('$base-wal'), File('$base-shm')];
      for (final f in files) {
        f.writeAsBytesSync([1, 2, 3]);
      }
    }

    await deleteOrphanStores(File(liveBase));

    final remaining = names(dir);
    expect(remaining, [
      'sis_store.sqlite',
      'sis_store.sqlite-shm',
      'sis_store.sqlite-wal',
    ]);

    for (final f in liveFiles) {
      expect(f.readAsBytesSync(), [1, 2, 3]);
    }
  });

  test('keeps unrelated files while deleting orphan sets', () async {
    final dir = await Directory.systemTemp.createTemp('sis-orphans-');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Unrelated files
    final unrelated = [
      File(p.join(dir.path, 'notes.txt')),
      File(p.join(dir.path, 'other.sqlite')),
      File(p.join(dir.path, 'sis_store.sqlite.bak')),
    ];
    for (final f in unrelated) {
      f.writeAsBytesSync([1, 2, 3]);
    }

    // Orphan set
    final base = p.join(dir.path, 'sis_store.orphan-1761000000.sqlite');
    final orphanFiles = [File(base), File('$base-wal'), File('$base-shm')];
    for (final f in orphanFiles) {
      f.writeAsBytesSync([1, 2, 3]);
    }

    await deleteOrphanStores(File(p.join(dir.path, 'sis_store.sqlite')));

    final remaining = names(dir);
    expect(remaining, ['notes.txt', 'other.sqlite', 'sis_store.sqlite.bak']);
  });

  test('no orphans: folder listing unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('sis-orphans-');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Live store files
    final liveBase = p.join(dir.path, 'sis_store.sqlite');
    final liveFiles = [
      File(liveBase),
      File('$liveBase-wal'),
      File('$liveBase-shm'),
    ];
    for (final f in liveFiles) {
      f.writeAsBytesSync([1, 2, 3]);
    }

    // Unrelated file
    final unrelated = File(p.join(dir.path, 'notes.txt'));
    unrelated.writeAsBytesSync([1, 2, 3]);

    final before = names(dir);
    await deleteOrphanStores(File(liveBase));
    final after = names(dir);

    expect(after, before);
  });

  test('empty folder and missing live file: completes without error', () async {
    final dir = await Directory.systemTemp.createTemp('sis-orphans-');
    addTearDown(() => dir.deleteSync(recursive: true));

    final liveFile = File(p.join(dir.path, 'sis_store.sqlite'));
    // Do not create the file

    await deleteOrphanStores(liveFile);

    final remaining = names(dir);
    expect(remaining, isEmpty);
  });

  test('lone orphan -wal without main .sqlite is deleted', () async {
    final dir = await Directory.systemTemp.createTemp('sis-orphans-');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Lone orphan-wal
    final orphanWal = File(
      p.join(dir.path, 'sis_store.orphan-1761000000.sqlite-wal'),
    );
    orphanWal.writeAsBytesSync([1, 2, 3]);

    await deleteOrphanStores(File(p.join(dir.path, 'sis_store.sqlite')));

    final remaining = names(dir);
    expect(remaining, isEmpty);
  });

  test('the folder does not exist: completes without error', () async {
    final dir = await Directory.systemTemp.createTemp('sis-orphans-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gone = Directory(p.join(dir.path, 'never-made'));

    await deleteOrphanStores(File(p.join(gone.path, 'sis_store.sqlite')));

    expect(gone.existsSync(), isFalse);
  });
}

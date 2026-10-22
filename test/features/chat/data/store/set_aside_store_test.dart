import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/store_location.dart';

void main() {
  final orphanRegex = RegExp(r'^sis_store\.orphan-(\d+)\.sqlite(-wal|-shm)?$');

  Directory? dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync();
  });

  tearDown(() async {
    if (dir != null && dir!.existsSync()) {
      dir!.deleteSync(recursive: true);
    }
  });

  Future<void> createFiles({
    bool main = true,
    bool wal = true,
    bool shm = true,
    String? otherContent,
  }) async {
    final mainPath = p.join(dir!.path, storeFileName);
    if (main) {
      await File(mainPath).writeAsString('main');
    }
    final walPath = p.join(dir!.path, '$storeFileName-wal');
    if (wal) {
      await File(walPath).writeAsString('wal');
    }
    final shmPath = p.join(dir!.path, '$storeFileName-shm');
    if (shm) {
      await File(shmPath).writeAsString('shm');
    }
    if (otherContent != null) {
      await File(p.join(dir!.path, 'other.txt')).writeAsString(otherContent);
    }
  }

  test('All three files present are renamed correctly', () async {
    await createFiles(otherContent: 'other');
    final bytesBefore = dir!.listSync().whereType<File>().fold<int>(
      0,
      (sum, f) => sum + f.lengthSync(),
    );

    final beforeSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final file = File(p.join(dir!.path, storeFileName));
    await setAsideStore(file);
    final afterSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final files = dir!.listSync();
    final orphanFiles = files
        .where((f) => f is File && orphanRegex.hasMatch(p.basename(f.path)))
        .cast<File>()
        .toList();

    expect(orphanFiles.length, 3);

    final ns = orphanFiles
        .map(
          (f) =>
              int.parse(orphanRegex.firstMatch(p.basename(f.path))!.group(1)!),
        )
        .toSet();
    expect(ns.length, 1);
    final n = ns.first;
    expect(n, inInclusiveRange(beforeSeconds, afterSeconds));

    final contents = <String, String>{};
    for (final f in orphanFiles) {
      final name = p.basename(f.path);
      if (name.endsWith('-wal')) {
        contents['wal'] = await f.readAsString();
      } else if (name.endsWith('-shm')) {
        contents['shm'] = await f.readAsString();
      } else {
        contents['main'] = await f.readAsString();
      }
    }
    expect(contents['main'], 'main');
    expect(contents['wal'], 'wal');
    expect(contents['shm'], 'shm');

    // Original files should not exist
    expect(File(p.join(dir!.path, storeFileName)).existsSync(), false);
    expect(File(p.join(dir!.path, '$storeFileName-wal')).existsSync(), false);
    expect(File(p.join(dir!.path, '$storeFileName-shm')).existsSync(), false);

    // Unrelated file remains unchanged
    final other = File(p.join(dir!.path, 'other.txt'));
    expect(other.existsSync(), true);
    expect(await other.readAsString(), 'other');

    // Never deletes: every byte is still in the folder, and nothing else is there.
    expect(
      files.whereType<File>().fold<int>(0, (sum, f) => sum + f.lengthSync()),
      bytesBefore,
    );
    expect(files.length, 4);
  });

  test('Only main file present is renamed correctly', () async {
    await createFiles(main: true, wal: false, shm: false);

    final beforeSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final file = File(p.join(dir!.path, storeFileName));
    await setAsideStore(file);
    final afterSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final files = dir!.listSync();
    final orphanFiles = files
        .where((f) => f is File && orphanRegex.hasMatch(p.basename(f.path)))
        .cast<File>()
        .toList();

    expect(orphanFiles.length, 1);
    expect(files.length, 1);
    final name = p.basename(orphanFiles.first.path);
    final match = orphanRegex.firstMatch(name)!;
    final n = int.parse(match.group(1)!);
    expect(n, inInclusiveRange(beforeSeconds, afterSeconds));
    expect(await orphanFiles.first.readAsString(), 'main');

    // Original main file should not exist
    expect(File(p.join(dir!.path, storeFileName)).existsSync(), false);
  });

  test('Only wal and shm present are renamed correctly', () async {
    await createFiles(main: false, wal: true, shm: true);

    final beforeSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final file = File(p.join(dir!.path, storeFileName));
    await setAsideStore(file);
    final afterSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final files = dir!.listSync();
    final orphanFiles = files
        .where((f) => f is File && orphanRegex.hasMatch(p.basename(f.path)))
        .cast<File>()
        .toList();

    expect(orphanFiles.length, 2);
    expect(files.length, 2, reason: 'no file is made for the missing main');
    final ns = orphanFiles
        .map(
          (f) =>
              int.parse(orphanRegex.firstMatch(p.basename(f.path))!.group(1)!),
        )
        .toSet();
    expect(ns.length, 1);
    final n = ns.first;
    expect(n, inInclusiveRange(beforeSeconds, afterSeconds));

    final contents = <String, String>{};
    for (final f in orphanFiles) {
      final name = p.basename(f.path);
      if (name.endsWith('-wal')) {
        contents['wal'] = await f.readAsString();
      } else if (name.endsWith('-shm')) {
        contents['shm'] = await f.readAsString();
      }
    }
    expect(contents['wal'], 'wal');
    expect(contents['shm'], 'shm');

    // Original wal and shm files should not exist
    expect(File(p.join(dir!.path, '$storeFileName-wal')).existsSync(), false);
    expect(File(p.join(dir!.path, '$storeFileName-shm')).existsSync(), false);
  });

  test('No files present does not throw and leaves folder empty', () async {
    final file = File(p.join(dir!.path, storeFileName));
    await setAsideStore(file);

    final files = dir!.listSync();
    expect(files.isEmpty, true);
  });
}

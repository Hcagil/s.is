// Opening the on-phone store must never delete a valid file: two openers
// racing on a new file, a reopen while another connection holds the file
// busy, and a busy file that never frees up. Only an unusable file (wrong
// key, not a database, another owner) resets. REAL SQLite3 Multiple Ciphers
// files in a temp directory; written from the contract, not the code.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  DriftMessageStore storeAt(File f, {String owner = 'owner-1', String? k}) {
    final s = DriftMessageStore(
      ownerId: owner,
      file: () async => f,
      key: () async => k ?? key,
      deleteKey: () async => h.deleteKeyCalls++,
    );
    addTearDown(s.close);
    return s;
  }

  /// A raw keyed connection holding an EXCLUSIVE lock on [f]; the probe
  /// proves the lock really makes other connections busy.
  sql.Database holdBusy(File f) {
    final raw = sql.sqlite3.open(f.path);
    raw.execute("PRAGMA key = \"x'$key'\";");
    raw.select('SELECT count(*) FROM sqlite_master');
    raw.execute('BEGIN EXCLUSIVE');
    final probe = sql.sqlite3.open(f.path);
    try {
      probe.execute("PRAGMA key = \"x'$key'\";");
      expect(
        () => probe.select('SELECT count(*) FROM sqlite_master'),
        throwsA(
          isA<sql.SqliteException>().having(
            (e) => e.resultCode,
            'resultCode',
            anyOf(5, 6), // BUSY, LOCKED
          ),
        ),
        reason: 'fixture: the lock makes another connection busy',
      );
    } finally {
      probe.close();
    }
    return raw;
  }

  group('a valid file is never deleted', () {
    test('two openers 0-40 ms apart on a NEW file: 42/42 saves kept', () async {
      final lost = <String>[];
      for (var d = 0; d <= 20; d++) {
        final f = File(p.join(h.dir.path, 'race_$d.sqlite'));
        final a = storeAt(f);
        final savedA = a.upsertAll([msg('a$d')]);
        await Future<void>.delayed(Duration(milliseconds: d * 2));
        final b = storeAt(f);
        final savedB = b.upsertAll([msg('b$d', t: 1)]);
        await Future.wait([savedA, savedB]);
        final kept = ids(await storeAt(f).newest('c1')).toSet();
        for (final id in ['a$d', 'b$d']) {
          if (!kept.contains(id)) lost.add(id);
        }
      }
      expect(lost, isEmpty, reason: '${42 - lost.length}/42 saves kept');
    });

    test('an existing store reopened twice at once keeps its data', () async {
      final first = storeAt(h.file);
      await first.upsertAll([for (var i = 0; i < 10; i++) msg('m$i', t: i)]);
      await first.close();
      final reads = await Future.wait([
        storeAt(h.file).newest('c1'),
        storeAt(h.file).newest('c1'),
      ]);
      for (final r in reads) {
        expect(ids(r), [for (var i = 0; i < 10; i++) 'm$i']);
      }
    });

    test('reopened while another connection holds it busy: the open waits '
        'and the data survives', () async {
      final first = storeAt(h.file);
      await first.upsertAll([msg('kept')]);
      await first.close();
      final raw = holdBusy(h.file);
      Timer(const Duration(milliseconds: 150), () {
        raw.execute('COMMIT');
        raw.close();
      });
      final s = storeAt(h.file);
      expect(ids(await s.newest('c1')), ['kept'], reason: 'retried the open');
      await s.upsertAll([msg('more', t: 1)]);
      expect(ids(await storeAt(h.file).newest('c1')), ['kept', 'more']);
    });

    test('busy for longer than every retry: falls back, never throws, '
        'and does not delete the file', () async {
      final first = storeAt(h.file);
      await first.upsertAll([msg('kept')]);
      await first.close();
      final raw = holdBusy(h.file);
      final s = storeAt(h.file);
      final watch = Stopwatch()..start();
      final r = await s.newest('c1').timeout(const Duration(seconds: 10));
      watch.stop();
      expect(r, isEmpty, reason: 'the fallback');
      expect(await h.file.exists(), isTrue, reason: 'file not deleted');
      raw.execute('COMMIT');
      raw.close();
      expect(
        ids(await storeAt(h.file).newest('c1')),
        ['kept'],
        reason:
            'busy is passing: the data survives (gave up after '
            '${watch.elapsedMilliseconds} ms)',
      );
    });
  });

  group('every other error keeps the file, and the open is bounded', () {
    test('a setup error (not owner, NOTADB or CORRUPT) keeps the existing '
        'file and its data', () async {
      final first = storeAt(h.file);
      await first.upsertAll([msg('kept')]);
      await first.close();
      // A key that breaks the PRAGMA: the setup fails with a plain SQL error.
      final broken = storeAt(h.file, k: "ab'\"; x");
      expect(
        await broken.newest('c1').timeout(const Duration(seconds: 10)),
        isEmpty,
        reason: 'the fallback',
      );
      await broken.close();
      expect(await h.file.exists(), isTrue, reason: 'file not deleted');
      expect(ids(await storeAt(h.file).newest('c1')), ['kept']);
    });

    test('a file that stays unusable after its one reset ends in the '
        'fallback, never spins', () async {
      // Garbage in a read-only directory: the reset cannot delete it.
      final dir = Directory(p.join(h.dir.path, 'ro'))..createSync();
      final f = File(p.join(dir.path, 'sis_store.sqlite'))
        ..writeAsBytesSync(List<int>.generate(8192, (i) => (i * 13) & 0xff));
      Process.runSync('chmod', ['0444', f.path]);
      Process.runSync('chmod', ['0555', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['-R', 'u+w', dir.path]));
      final s = storeAt(f);
      expect(
        await s.newest('c1').timeout(const Duration(seconds: 10)),
        isEmpty,
      );
      expect(
        await s.cursor().timeout(const Duration(seconds: 10)),
        isNull,
        reason: 'a later call is bounded too',
      );
    });
  });

  group('an unusable file resets', () {
    test('wrong key surfaces from sqlite3mc as NOTADB (26)', () async {
      final s = storeAt(h.file);
      await s.upsertAll([msg('old')]);
      await s.close();
      final other = await h.newKey();
      final raw = sql.sqlite3.open(h.file.path);
      addTearDown(raw.close);
      raw.execute("PRAGMA key = \"x'$other'\";");
      expect(
        () => raw.select('SELECT count(*) FROM sqlite_master'),
        throwsA(
          isA<sql.SqliteException>().having(
            (e) => e.resultCode,
            'resultCode',
            26,
          ),
        ),
      );
    });

    test('wrong key: the store resets, is re-keyed, and works', () async {
      final s = storeAt(h.file);
      await s.upsertAll([msg('old')]);
      await s.close();
      final other = await h.newKey();
      final r = storeAt(h.file, k: other);
      expect(await r.newest('c1'), isEmpty);
      await r.upsertAll([msg('new')]);
      await r.close();
      // The file now opens with the new key only.
      final raw = sql.sqlite3.open(h.file.path);
      addTearDown(raw.close);
      raw.execute("PRAGMA key = \"x'$other'\";");
      expect(
        raw.select('SELECT count(*) AS n FROM sqlite_master').first['n'],
        greaterThan(0),
      );
      expect(ids(await storeAt(h.file, k: other).newest('c1')), ['new']);
    });

    test('another owner: resets, the new owner keeps its data', () async {
      final s = storeAt(h.file);
      await s.upsertAll([msg('mine')]);
      await s.close();
      final b = storeAt(h.file, owner: 'owner-2');
      expect(await b.newest('c1'), isEmpty);
      await b.upsertAll([msg('theirs')]);
      expect(ids(await storeAt(h.file, owner: 'owner-2').newest('c1')), [
        'theirs',
      ]);
    });
  });
}

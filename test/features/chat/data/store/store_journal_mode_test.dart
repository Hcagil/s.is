// Store open, slice 1: on Android the store opens with journal_mode wal; on
// other platforms it is unchanged (delete). Real sqlite3mc files.
// The Android branch keys off dart:io Platform, which a host test cannot
// switch; its wrong-key reset was checked by forcing that branch on (see the
// QA report), and the premise it relies on is pinned here: with WAL set right
// after PRAGMA key, a wrong key fails at that pragma with the same NOTADB (26)
// the reset path already handles.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  setUp(() async => h = await StoreHarness.create());

  String modeOf(String key) {
    final raw = sql.sqlite3.open(h.file.path);
    addTearDown(raw.close);
    raw.execute("PRAGMA key = \"x'$key'\";");
    return raw.select('PRAGMA journal_mode').first.values.first! as String;
  }

  test('off Android the store file keeps journal_mode delete', () async {
    final key = await h.newKey();
    final s = h.open(owner: 'me', key: key);
    await s.upsertAll([msg('a')]);
    await s.close();
    expect(modeOf(key), 'delete');
    expect(h.wal.existsSync(), isFalse, reason: 'no -wal file');
  }, skip: Platform.isAndroid ? 'host-only check' : false);

  test('a wrong key fails at PRAGMA journal_mode = WAL with NOTADB (26), the '
      'code the reset path handles', () async {
    final key = await h.newKey();
    final s = h.open(owner: 'me', key: key);
    await s.upsertAll([msg('a')]);
    await s.close();
    final other = await h.newKey();
    final raw = sql.sqlite3.open(h.file.path);
    addTearDown(raw.close);
    raw.execute("PRAGMA key = \"x'$other'\";");
    expect(
      () => raw.execute('PRAGMA journal_mode = WAL;'),
      throwsA(
        isA<sql.SqliteException>().having((e) => e.resultCode, 'code', 26),
      ),
    );
  });
}

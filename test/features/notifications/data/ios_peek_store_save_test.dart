// The iPhone notification extension's one write (ios/NotificationService/
// PeekStore.c, sis_peek_save) against a REAL SQLite3 Multiple Ciphers file
// made by the production drift schema 5 (DriftMessageStore +
// DriftChatListSnapshotStore), never a hand-made table: a column rename in
// tables.dart must break these tests. Mirrors the Android writer tests
// (test/features/crypto/data/push_inbox_writer_test.dart).
// Written from the header and the contract (t_176cbd956f), never from the
// implementation. Codes: 0 saved, 1 user_version < 5 (nothing written),
// 2 busy after about 500 ms, 3 skipped (messages row exists or no
// conversations row), 4 any other error / not readable. Never creates a file
// or table; the connection is closed before it returns.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/push_inbox_store.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../../chat/data/store/store_harness.dart';
import 'peek_c_build.dart';

final _sealed = 'c0ffee' * 10 + 'abcd'; // 64 hex chars
final _rx = DateTime.utc(2026, 3, 1, 9, 30, 0, 0, 456).microsecondsSinceEpoch;

typedef _SaveC = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Int64,
);
typedef _Save = int Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
);

final _libc = DynamicLibrary.process();
final _calloc = _libc
    .lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr),
      Pointer<Void> Function(int, int)
    >('calloc');
final _free = _libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );

Pointer<Uint8> _c(String? s) {
  if (s == null) return nullptr;
  final b = utf8.encode(s);
  final p = _calloc(b.length + 1, 1).cast<Uint8>();
  p.asTypedList(b.length).setAll(0, b);
  return p;
}

/// A sentinel: pass a NULL pointer for this argument.
const _null = '\u0000null';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late _Save save;
  late String lockTool;
  late StoreHarness h;
  late String key;
  final opened = <DriftMessageStore>[];

  setUpAll(() async {
    final so = await buildPeekLib();
    save = DynamicLibrary.open(so)
        .lookupFunction<_SaveC, _Save>('sis_peek_save');
    File(so).deleteSync();
    lockTool = await buildLockTool();
  });
  tearDownAll(() {
    if (File(lockTool).existsSync()) File(lockTool).deleteSync();
  });

  DriftMessageStore open() {
    final s = h.open(owner: 'bob', key: key);
    opened.add(s);
    return s;
  }

  int write({
    String? path,
    String? keyHex,
    String conv = 'c1',
    String id = 'n1',
    String peer = 'alice',
    String body = 'merhaba',
    String? sealed,
  }) {
    String? n(String s) => s == _null ? null : s;
    final args = [
      _c(n(path ?? h.file.path)),
      _c(n(keyHex ?? key)),
      _c(n(conv)),
      _c(n(id)),
      _c(n(peer)),
      _c(n(body)),
      _c(n(sealed ?? _sealed)),
    ];
    try {
      return save(
        args[0],
        args[1],
        args[2],
        args[3],
        args[4],
        args[5],
        args[6],
        _rx,
      );
    } finally {
      for (final a in args) {
        if (a != nullptr) _free(a.cast());
      }
    }
  }

  sql.Database raw() {
    final db = sql.sqlite3.open(h.file.path);
    db.execute("PRAGMA key = \"x'$key'\";");
    return db;
  }

  /// The raw push_inbox rows, read with a separate connection.
  List<Map<String, Object?>> rawRows() {
    final db = raw();
    try {
      return [
        for (final r in db.select('SELECT * FROM push_inbox')) {...r},
      ];
    } finally {
      db.close();
    }
  }

  String journalMode() {
    final db = raw();
    try {
      return db.select('PRAGMA journal_mode').first.values.first as String;
    } finally {
      db.close();
    }
  }

  /// One write by ANOTHER process with no busy wait: fails if a lock is left.
  Future<String> otherProcessWrites() async {
    final r = await Process.run(lockTool, [h.file.path, key, 'write']);
    return (r.stdout as String).trim();
  }

  /// Another process holds the write lock for [ms]; resolves once taken.
  Future<(Process, StreamIterator<String>)> otherProcessHolds(
    int ms, {
    String mode = 'IMMEDIATE',
  }) async {
    final p = await Process.start(lockTool, [
      h.file.path,
      key,
      'hold',
      '$ms',
      mode,
    ]);
    final lines = StreamIterator(
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, 'locked');
    return (p, lines);
  }

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    opened.clear();
    final app = open();
    await DriftChatListSnapshotStore(app).save('bob', const [
      Conversation(
        id: 'c1',
        other: Member(userId: 'alice', displayName: 'Alice'),
      ),
    ]);
    await app.close();
    addTearDown(() async {
      for (final o in opened) {
        await o.close();
      }
    });
  });

  test('saved: one row with exactly the given values in the drift schema '
      'columns; the app reads it back', () async {
    expect(write(), 0);
    final rows = rawRows();
    expect(rows, hasLength(1));
    expect(rows.single, {
      'message_id': 'n1',
      'conversation_id': 'c1',
      'sender_id': 'alice',
      'body': 'merhaba',
      'sealed': _sealed,
      'received_at': _rx,
    });
    final m = (await (open() as PushInboxStore).pushInbox()).single;
    expect(
      (m.id, m.conversationId, m.senderId, m.body),
      ('n1', 'c1', 'alice', 'merhaba'),
    );
    expect(m.createdAt.microsecondsSinceEpoch, _rx);
  });

  test('a body with non-ASCII text and quotes is stored as given', () {
    const body = "Günaydın 'ş' \"ğ\" 🔒";
    expect(write(body: body), 0);
    expect(rawRows().single['body'], body);
  });

  test('a repeated push => 3 and still one row with the first body', () {
    expect(write(body: 'first'), 0);
    expect(write(body: 'second'), 3);
    expect(rawRows().map((r) => r['body']), ['first']);
  });

  test('the race: the real message row is stored first => 3, no inbox '
      'row', () async {
    final s = open();
    await s.upsertAll([msg('n1', sender: 'alice', body: 'real')]);
    await s.close();
    expect(write(), 3);
    expect(rawRows(), isEmpty);
  });

  test('W2: a chat with no conversations row => 3, nothing written', () {
    expect(write(conv: 'c9'), 3);
    expect(rawRows(), isEmpty);
  });

  test('old schema (user_version 4, the app updated but not opened): 1, no '
      'table created, file byte-for-byte unchanged', () async {
    final s = open();
    await s.run<void>(null, (db) async {
      await db.customStatement('DROP TRIGGER push_inbox_ai');
      await db.customStatement('DROP TRIGGER push_inbox_au');
      await db.customStatement('DROP TABLE push_inbox');
      await db.customStatement('PRAGMA user_version = 4');
    }, write: true);
    await s.close();
    final before = await h.file.readAsBytes();

    expect(write(), 1);

    expect(await h.file.readAsBytes(), before);
    final db = raw();
    addTearDown(db.close);
    expect(
      db.select("SELECT name FROM sqlite_master WHERE name = 'push_inbox'"),
      isEmpty,
    );
  });

  test('old schema with the table already there (user_version 4) => 1, no '
      'row', () async {
    final s = open();
    await s.run<void>(null, (db) async {
      await db.customStatement('PRAGMA user_version = 4');
    }, write: true);
    await s.close();
    expect(write(), 1);
    expect(rawRows(), isEmpty);
  });

  test('missing file => 4 and no file or journal is created', () {
    final missing = '${h.dir.path}/nope.sqlite';
    expect(write(path: missing), 4);
    expect(File(missing).existsSync(), isFalse);
    expect(File('$missing-journal').existsSync(), isFalse);
    expect(File('$missing-wal').existsSync(), isFalse);
  });

  test('wrong key => 4, file byte-for-byte unchanged, the app still opens '
      'it (not reset)', () async {
    final before = await h.file.readAsBytes();
    expect(write(keyHex: await h.newKey()), 4);
    expect(await h.file.readAsBytes(), before);
    final s = open();
    expect(await (s as PushInboxStore).pushInbox(), isEmpty);
    expect(
      (await DriftChatListSnapshotStore(s).load('bob'))?.map((c) => c.id),
      ['c1'],
      reason: 'store not reset',
    );
  });

  test('a garbage file => 4, left as it was', () {
    final junk = File('${h.dir.path}/junk.sqlite')
      ..writeAsStringSync('not a database at all' * 100);
    final before = junk.readAsBytesSync();
    expect(write(path: junk.path), 4);
    expect(junk.readAsBytesSync(), before);
  });

  test('bad arguments (NULL, a key that is not 64 hex) => 4, nothing '
      'written', () {
    for (final bad in <int Function()>[
      () => write(path: _null),
      () => write(keyHex: _null),
      () => write(conv: _null),
      () => write(id: _null),
      () => write(peer: _null),
      () => write(body: _null),
      () => write(sealed: _null),
      () => write(keyHex: key.substring(1)),
      () => write(keyHex: '${key}00'),
      () => write(keyHex: 'zz${key.substring(2)}'),
    ]) {
      expect(bad(), 4);
    }
    expect(rawRows(), isEmpty);
  });

  test('a key with SQL after it is refused before it reaches the PRAGMA: '
      '4 and the file is byte-for-byte unchanged', () async {
    final before = await h.file.readAsBytes();
    // Fits the PRAGMA text; without the 64-hex check it would key the store
    // with the right key and then run VACUUM (rewrites every page).
    expect(write(keyHex: '$key\'";VACUUM;--'), 4);
    expect(await h.file.readAsBytes(), before);
    expect(rawRows(), isEmpty);
  });

  test('journal mode is unchanged (not wal) and no -wal file after a '
      'save', () {
    final mode = journalMode();
    expect(mode, isNot('wal'), reason: 'fixture: the iPhone store');
    expect(write(), 0);
    expect(journalMode(), mode);
    expect(h.wal.existsSync(), isFalse);
  });

  test('right after every kind of result another process writes at once '
      '(the connection is closed, no lock left)', () async {
    expect(write(), 0);
    expect(await otherProcessWrites(), 'written');
    expect(write(), 3);
    expect(await otherProcessWrites(), 'written');
    expect(write(conv: 'c9', id: 'n2'), 3);
    expect(await otherProcessWrites(), 'written');
    expect(write(keyHex: await h.newKey()), 4);
    expect(await otherProcessWrites(), 'written');
    // And the app itself writes and reads.
    final s = open();
    await s.upsertAll([msg('m1', sender: 'alice')]);
    expect(ids(await s.newest('c1')), ['m1']);
  });

  test('after an old-schema result another process writes at once', () async {
    final s = open();
    await s.run<void>(null, (db) async {
      await db.customStatement('PRAGMA user_version = 4');
    }, write: true);
    await s.close();
    expect(write(), 1);
    expect(await otherProcessWrites(), 'written');
  });

  group('another process (the app) holds the write lock', () {
    for (final mode in ['IMMEDIATE', 'EXCLUSIVE']) {
      test('BEGIN $mode held => 2 after about 500 ms, nothing written; the '
          'holder commits; then a save works', () async {
        final (p, _) = await otherProcessHolds(5000, mode: mode);
        final sw = Stopwatch()..start();
        final code = write();
        final ms = sw.elapsedMilliseconds;
        p.kill();
        await p.exitCode;
        expect(code, 2);
        expect(ms, greaterThanOrEqualTo(400), reason: 'retried up to the cap');
        // 500 ms cap plus at most one 100 ms busy_timeout per statement of
        // the last try: about 0.85 s worst case (security re-gate Info 2).
        expect(ms, lessThan(1000), reason: 'cap about 500 ms');
        expect(rawRows(), isEmpty);
        expect(write(), 0, reason: 'lock gone: saves again');
      });
    }

    test('busy leaves no lock: the holder still commits, and another process '
        'writes right after', () async {
      final (p, lines) = await otherProcessHolds(900);
      expect(write(), 2);
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, 'released', reason: 'the app commit succeeded');
      expect(await p.exitCode, 0);
      expect(await otherProcessWrites(), 'written');
    });

    test('a lock released within the cap is waited for: saved', () async {
      final (p, lines) = await otherProcessHolds(200);
      final sw = Stopwatch()..start();
      final code = write();
      final ms = sw.elapsedMilliseconds;
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, 'released');
      expect(await p.exitCode, 0);
      expect(code, 0);
      expect(ms, greaterThanOrEqualTo(100), reason: 'it did wait');
      expect(rawRows(), hasLength(1));
    });
  });
}

// writePushInbox (the Android push engine's one write) against a REAL
// SQLite3 Multiple Ciphers file made by the production drift schema 5
// (DriftMessageStore + DriftChatListSnapshotStore), never a hand-made table:
// a column rename in tables.dart must break these tests.
// Written from the contract (t_0f04c69ee7 design 1 and 4, t_428ad7c883 QA
// contract), never from the implementation. Codes: saved, inbox_budget
// (< 500 ms), inbox_old_schema (user_version < 5), inbox_busy (cap
// min(500, budget - 250) ms), inbox_skip (messages row exists or no
// conversations row), inbox_error. Never creates a file or table, never
// deletes or recreates anything, closes its connection.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/push_inbox_store.dart';
import 'package:sis/features/crypto/data/push_inbox_writer.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../../chat/data/store/store_harness.dart';

final _sealed = 'c0ffee' * 10 + 'abcd'; // 64 hex chars
final _rx = DateTime.utc(2026, 3, 1, 9, 30, 0, 0, 456).microsecondsSinceEpoch;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late StoreHarness h;
  late String key;
  late DriftMessageStore app;
  final opened = <DriftMessageStore>[];

  DriftMessageStore open() {
    final s = h.open(owner: 'bob', key: key);
    opened.add(s);
    return s;
  }

  String write({
    String? path,
    String? keyHex,
    String conv = 'c1',
    String id = 'n1',
    String peer = 'alice',
    String body = 'merhaba',
    int budget = 3000,
  }) => writePushInbox(
    path: path ?? h.file.path,
    keyHex: keyHex ?? key,
    conversationId: conv,
    messageId: id,
    peerUserId: peer,
    body: body,
    sealed: _sealed,
    receivedAtMicros: _rx,
    budgetMs: budget,
  );

  Future<List<String>> inbox([DriftMessageStore? s]) async =>
      ids(await ((s ?? open()) as PushInboxStore).pushInbox());

  /// The raw push_inbox rows, read with a separate connection.
  List<Map<String, Object?>> rawRows() {
    final db = sql.sqlite3.open(h.file.path);
    try {
      db.execute("PRAGMA key = \"x'$key'\";");
      return [
        for (final r in db.select('SELECT * FROM push_inbox')) {...r},
      ];
    } finally {
      db.close();
    }
  }

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    opened.clear();
    addTearDown(() async {
      for (final o in opened) {
        await o.close();
      }
    });
    app = open();
    await DriftChatListSnapshotStore(app).save('bob', const [
      Conversation(
        id: 'c1',
        other: Member(userId: 'alice', displayName: 'Alice'),
      ),
    ]);
  });

  group('app closed (cold push)', () {
    setUp(() => app.close());

    test('saved: one row with exactly the given values in the drift schema '
        'columns', () async {
      expect(write(), 'saved');
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
      // The app reads it back through PushInboxStore.
      final m = (await (open() as PushInboxStore).pushInbox()).single;
      expect(
        (m.id, m.conversationId, m.senderId, m.body),
        ('n1', 'c1', 'alice', 'merhaba'),
      );
      expect(m.createdAt.microsecondsSinceEpoch, _rx);
    });

    test('W2: a chat with no conversations row => inbox_skip, nothing '
        'written', () async {
      expect(write(conv: 'c9'), 'inbox_skip');
      expect(rawRows(), isEmpty);
    });

    test('the race: the server row is stored first => inbox_skip, no inbox '
        'row', () async {
      final s = open();
      await s.upsertAll([msg('n1', sender: 'alice', body: 'real')]);
      await s.close();
      expect(write(), 'inbox_skip');
      expect(rawRows(), isEmpty);
    });

    test('a replayed push keeps one row, the first body', () async {
      expect(write(body: 'first'), 'saved');
      final again = write(body: 'second');
      expect(again, isNot('inbox_error'));
      expect(rawRows().map((r) => r['body']), ['first']);
    });

    test('budget: 499 ms left => inbox_budget and the file is untouched; '
        '500 ms => saved', () async {
      final before = await h.file.readAsBytes();
      expect(write(budget: 499), 'inbox_budget');
      expect(write(budget: 0), 'inbox_budget');
      expect(await h.file.readAsBytes(), before);
      expect(write(budget: 500), 'saved');
    });

    test('old schema (user_version 4, the app updated but not opened): '
        'inbox_old_schema, no table created, file unchanged', () async {
      final s = open();
      await s.run<void>(null, (db) async {
        await db.customStatement('DROP TRIGGER push_inbox_ai');
        await db.customStatement('DROP TRIGGER push_inbox_au');
        await db.customStatement('DROP TABLE push_inbox');
        await db.customStatement('PRAGMA user_version = 4');
      }, write: true);
      await s.close();
      final before = await h.file.readAsBytes();

      expect(write(), 'inbox_old_schema');

      expect(await h.file.readAsBytes(), before);
      final db = sql.sqlite3.open(h.file.path);
      addTearDown(db.close);
      db.execute("PRAGMA key = \"x'$key'\";");
      expect(
        db.select("SELECT name FROM sqlite_master WHERE name = 'push_inbox'"),
        isEmpty,
      );
    });

    test('old schema with the table already there (user_version 4) still '
        'writes nothing', () async {
      final s = open();
      await s.run<void>(null, (db) async {
        await db.customStatement('PRAGMA user_version = 4');
      }, write: true);
      await s.close();
      expect(write(), 'inbox_old_schema');
      expect(rawRows(), isEmpty);
    });

    test('missing file => inbox_error and no file is created', () async {
      final missing = '${h.dir.path}/nope.sqlite';
      expect(write(path: missing), 'inbox_error');
      expect(File(missing).existsSync(), isFalse);
      expect(File('$missing-journal').existsSync(), isFalse);
    });

    test('wrong key => inbox_error, file byte-for-byte unchanged and the app '
        'still opens it', () async {
      final before = await h.file.readAsBytes();
      expect(write(keyHex: await h.newKey()), 'inbox_error');
      expect(await h.file.readAsBytes(), before);
      expect(await inbox(), isEmpty);
      expect(
        (await DriftChatListSnapshotStore(opened.last).load('bob'))
            ?.map((c) => c.id),
        ['c1'],
        reason: 'store not reset',
      );
    });

    test('never throws on a garbage file, leaves it as it was', () async {
      final junk = File('${h.dir.path}/junk.sqlite')
        ..writeAsStringSync('not a database at all' * 100);
      final before = junk.readAsBytesSync();
      expect(write(path: junk.path), 'inbox_error');
      expect(junk.readAsBytesSync(), before);
    });
  });

  group('app open in the same process (Android, app alive)', () {
    test('saved while the app holds its connection; the app sees it on its '
        'next read and can still write at once', () async {
      expect(await inbox(app), isEmpty);
      expect(write(), 'saved');
      expect(await inbox(app), ['n1']);
      final sw = Stopwatch()..start();
      await app.upsertAll([msg('n1', sender: 'alice', body: 'real')]);
      expect(sw.elapsedMilliseconds, lessThan(1000), reason: 'no lock left');
      expect(await inbox(app), isEmpty, reason: 'trigger: the app row wins');
    });

    test('busy: another connection holds the write lock => inbox_busy after '
        'the 500 ms cap; the lock holder is unaffected', () async {
      final holder = sql.sqlite3.open(h.file.path);
      addTearDown(holder.close);
      holder.execute("PRAGMA key = \"x'$key'\";");
      holder.execute('BEGIN IMMEDIATE;');
      holder.execute("UPDATE meta SET value = value WHERE key = 'owner_id';");

      final sw = Stopwatch()..start();
      expect(write(budget: 5000), 'inbox_busy');
      final ms = sw.elapsedMilliseconds;
      expect(ms, greaterThanOrEqualTo(400), reason: 'retried up to the cap');
      expect(ms, lessThan(1200), reason: 'cap 500 ms, never the budget');

      holder.execute('COMMIT;');
      expect(rawRows(), isEmpty);
      expect(write(), 'saved', reason: 'lock gone: writes again');
    });

    test('busy with little budget: the cap is budget - 250 ms (600 => '
        '350 ms)', () async {
      final holder = sql.sqlite3.open(h.file.path);
      addTearDown(holder.close);
      holder.execute("PRAGMA key = \"x'$key'\";");
      holder.execute('BEGIN EXCLUSIVE;');
      holder.execute("UPDATE meta SET value = value WHERE key = 'owner_id';");
      final sw = Stopwatch()..start();
      expect(write(budget: 600), 'inbox_busy');
      final ms = sw.elapsedMilliseconds;
      holder.execute('ROLLBACK;');
      expect(ms, greaterThanOrEqualTo(250));
      expect(ms, lessThan(500), reason: 'gives up before the push time ends');
    });

    test('a lock released within the cap is waited for: saved', () async {
      await app.close();
      final locked = ReceivePort();
      await Isolate.spawn(_holdLock, [h.file.path, key, locked.sendPort, 200]);
      final events = StreamIterator(locked);
      expect(await events.moveNext(), isTrue); // lock taken
      final sw = Stopwatch()..start();
      final code = write(budget: 5000);
      final ms = sw.elapsedMilliseconds;
      expect(await events.moveNext(), isTrue); // released
      locked.close();
      expect(code, 'saved');
      expect(ms, greaterThanOrEqualTo(100), reason: 'it did wait');
    });

    test('an app write started just before the push write: both '
        'land, the app write is not lost', () async {
      // Same isolate: the app write is queued around the synchronous push write.
      final f = app.upsertAll([msg('m1', sender: 'alice')]);
      expect(write(id: 'n2'), 'saved');
      await f;
      expect(ids(await app.newest('c1')), ['m1']);
      expect(await inbox(app), ['n2']);
    });
  });

  group('Android WAL (slice 1)', () {
    void toWal() {
      final db = sql.sqlite3.open(h.file.path);
      db.execute("PRAGMA key = \"x'$key'\";");
      expect(db.select('PRAGMA journal_mode = WAL').first.values.first, 'wal');
      db.close();
    }

    test('WAL with the app connection open (-shm present): saved, the app '
        'reads it', () async {
      await app.close();
      toWal();
      final s = open();
      await s.upsertAll([msg('m1', sender: 'alice')]);
      expect(h.shm.existsSync(), isTrue, reason: 'fixture: -shm exists');
      expect(write(), 'saved');
      expect(await inbox(s), ['n1']);
    });

    test('WAL with no connection open (cold push): saved, the app reads '
        'it', () async {
      await app.close();
      toWal();
      expect(write(), 'saved');
      expect(await inbox(), ['n1']);
    });
  });
}

/// Another connection (the app writing) holds an EXCLUSIVE lock for args[3] ms.
void _holdLock(List<Object> args) {
  final db = sql.sqlite3.open(args[0] as String);
  db.execute("PRAGMA key = \"x'${args[1]}'\";");
  db.execute('BEGIN EXCLUSIVE;');
  db.execute("UPDATE meta SET value = value WHERE key = 'owner_id';");
  final port = args[2] as SendPort;
  port.send('locked');
  sleep(Duration(milliseconds: args[3] as int));
  db.execute('COMMIT;');
  db.close();
  port.send('released');
}

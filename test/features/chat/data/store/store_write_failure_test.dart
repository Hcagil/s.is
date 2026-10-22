// Private Chats 4b Group J: a store write that keeps failing is no longer
// skipped in silence. Written from the contract (QA interface of the Group J
// report), never from the code:
// - upsertAll, reconcilePage, extendOlder, remove, deleteConversation,
//   saveCursor and SendQueueStore.save throw StoreWriteException when the
//   write keeps failing after its retries, or when the store cannot open;
//   its toString is just 'StoreWriteException' (no SQL text, no row data);
// - a closed, erased or owner-less store, and a write that loses the race
//   against an erase, return normally;
// - reads still fall back and never throw;
// - run(fallback, body) without write is unchanged: a failing body gives the
//   fallback.
// The failure is real: another connection holds the database file in an
// EXCLUSIVE lock, so every write of the store is refused as busy.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_send_queue_store.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'store_harness.dart';

const _secret = 'meet at the old bridge at 6';
const _bound = Duration(seconds: 40);
final _throwsWrite = throwsA(isA<StoreWriteException>());

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  DriftMessageStore open({String owner = 'owner-1'}) {
    final s = h.open(owner: owner, key: key);
    addTearDown(s.close);
    return s;
  }

  /// A raw keyed connection that holds the file in an EXCLUSIVE lock until
  /// the test ends; the probe proves another connection really cannot write.
  sql.Database lockFile() {
    final raw = sql.sqlite3.open(h.file.path);
    raw.execute("PRAGMA key = \"x'$key'\";");
    raw.select('SELECT count(*) FROM sqlite_master');
    raw.execute('BEGIN EXCLUSIVE');
    final probe = sql.sqlite3.open(h.file.path);
    try {
      probe.execute("PRAGMA key = \"x'$key'\";");
      probe.execute('PRAGMA busy_timeout = 0');
      expect(
        () => probe.execute('CREATE TABLE probe_t(x)'),
        throwsA(isA<sql.SqliteException>()),
        reason: 'fixture: the lock refuses another writer',
      );
    } finally {
      probe.close();
    }
    addTearDown(() {
      try {
        raw.execute('ROLLBACK');
      } on sql.SqliteException catch (_) {}
      raw.close();
    });
    return raw;
  }

  QueuedRecord queued(String id) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime(2026, 10, 22, 9),
    body: _secret,
  );

  /// Every write path of the contract, on [s].
  Map<String, Future<void> Function()> writes(DriftMessageStore s) => {
    'upsertAll': () => s.upsertAll([msg('w1', t: 10, body: _secret)]),
    'reconcilePage': () =>
        s.reconcilePage('c1', [msg('w2', t: 11)], reachedStart: false),
    'extendOlder': () =>
        s.extendOlder('c1', [msg('w0', t: 0)], reachedStart: true),
    'remove': () => s.remove('seed-2'),
    'deleteConversation': () => s.deleteConversation('c1'),
    'saveCursor': () => s.saveCursor(ChangeCursor(at(20), 'w9')),
    'SendQueueStore.save': () =>
        DriftSendQueueStore(s).save('owner-1', [queued('q1')]),
  };

  /// A store with c1 reconciled (so extendOlder has a sync state to lower).
  Future<DriftMessageStore> seeded() async {
    final s = open();
    await s.reconcilePage('c1', [
      msg('seed-1', t: 2),
      msg('seed-2', t: 3),
    ], reachedStart: false);
    return s;
  }

  group('a write that keeps failing throws StoreWriteException', () {
    for (final name in [
      'upsertAll',
      'reconcilePage',
      'extendOlder',
      'remove',
      'deleteConversation',
      'saveCursor',
      'SendQueueStore.save',
    ]) {
      test('$name: the file is locked by another connection', () async {
        final s = await seeded();
        lockFile();
        await expectLater(writes(s)[name]!().timeout(_bound), _throwsWrite);
      });

      test('$name: the store cannot open', () async {
        final first = await seeded();
        await first.close();
        lockFile();
        final s = open();
        await expectLater(writes(s)[name]!().timeout(_bound), _throwsWrite);
      });
    }

    test('the exception carries no SQL text and no row data', () async {
      final s = await seeded();
      lockFile();
      Object? caught;
      try {
        await s.upsertAll([msg('w1', t: 10, body: _secret)]).timeout(_bound);
      } on StoreWriteException catch (e) {
        caught = e;
      }
      expect(caught, isA<StoreWriteException>());
      expect(caught.toString(), 'StoreWriteException');
      expect(const StoreWriteException().toString(), 'StoreWriteException');
    });

    test('reads under the same lock still answer and never throw', () async {
      final s = await seeded();
      lockFile();
      await expectLater(s.newest('c1').timeout(_bound), completes);
      await expectLater(s.cursor().timeout(_bound), completes);
      await expectLater(s.syncState('c1').timeout(_bound), completes);
      await expectLater(s.search('hello').timeout(_bound), completes);
      await expectLater(
        DriftSendQueueStore(s).load('owner-1').timeout(_bound),
        completes,
      );
    });

    test('once the lock is gone the same store writes again', () async {
      final s = await seeded();
      final raw = lockFile();
      await expectLater(
        s.upsertAll([msg('w1', t: 10)]).timeout(_bound),
        _throwsWrite,
      );
      raw.execute('ROLLBACK');
      await s.upsertAll([msg('w1', t: 10)]).timeout(_bound);
      expect(ids(await s.newest('c1')), contains('w1'));
    });
  });

  group('skipped on purpose: returns normally', () {
    test('a closed store', () async {
      final s = await seeded();
      await s.close();
      for (final MapEntry(:key, :value) in writes(s).entries) {
        await expectLater(value().timeout(_bound), completes, reason: key);
      }
    });

    test('a store with no owner', () async {
      final s = open(owner: '');
      for (final MapEntry(:key, :value) in writes(s).entries) {
        await expectLater(value().timeout(_bound), completes, reason: key);
      }
    });

    test('an erased store (after clear)', () async {
      final s = await seeded();
      await s.clear();
      for (final MapEntry(:key, :value) in writes(s).entries) {
        await expectLater(value().timeout(_bound), completes, reason: key);
      }
    });

    test('a write racing an erase while the store is still opening', () async {
      final late = Completer<void>();
      final s = DriftMessageStore(
        ownerId: 'owner-1',
        file: () async => h.file,
        key: () async {
          await late.future;
          return key;
        },
        deleteKey: () async => h.deleteKeyCalls++,
      );
      addTearDown(s.close);
      final w = s.upsertAll([msg('w1', body: _secret)]);
      final c = s.saveCursor(ChangeCursor(at(1), 'w1'));
      final erase = s.clear();
      late.complete();
      await expectLater(w.timeout(_bound), completes);
      await expectLater(c.timeout(_bound), completes);
      await erase.timeout(_bound);
    });
  });

  group('run(fallback, body)', () {
    test('without write: a failing body gives the fallback', () async {
      final s = open();
      final r = await s
          .run<int>(7, (db) async => throw StateError(_secret))
          .timeout(_bound);
      expect(r, 7);
    });

    test('with write: a body that keeps failing throws '
        'StoreWriteException', () async {
      final s = open();
      await expectLater(
        s
            .run<int>(7, (db) async => throw StateError(_secret), write: true)
            .timeout(_bound),
        _throwsWrite,
      );
    });

    test('with write: a body that works returns its value', () async {
      final s = open();
      expect(await s.run<int>(7, (db) async => 3, write: true), 3);
    });
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' show Database;

import '../../domain/message.dart';
import '../../domain/message_store.dart';
import 'message_row_mapper.dart';
import 'store_database.dart';

/// The on-phone message store, one encrypted SQLite file; every method best-effort, never throws.
final class DriftMessageStore implements MessageStore {
  DriftMessageStore({
    required this.ownerId,
    required this._file,
    required this._key,
    required this._deleteKey,
  });
  final String ownerId;
  final Future<File> Function() _file;
  final Future<String> Function() _key;
  final Future<void> Function() _deleteKey;
  Future<StoreDatabase>? _db;
  bool _closed = false;

  /// Bumped by every clear() in the process; an instance whose work began before a bump lost to that erase.
  static int _erasures = 0;
  int? _seen;

  /// The process-wide erase count (every clear() on any instance raises it).
  int get erasures => _erasures;

  /// Operations running now (registered synchronously when they start).
  final _inflight = <Future<void>>{};

  /// The clear in progress or last finished; new work waits for it.
  Future<void>? _clearing;

  Future<StoreDatabase> _open() {
    final clearing = _clearing;
    if (clearing == null) return _openCached();
    return clearing.then((_) => _openCached());
  }

  /// The cached open; one that failed is forgotten so the next call tries again.
  Future<StoreDatabase> _openCached() {
    final opening = _db ??= _create();
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_db, opening)) _db = null;
      },
    );
    return opening;
  }

  /// Runs [body] on the open database for a sibling store (the chat list
  /// snapshot); any failure returns [fallback].
  Future<T> run<T>(T fallback, Future<T> Function(StoreDatabase db) body) =>
      _run(fallback, body);

  /// Runs [body] on the open database; any failure returns [fallback].
  Future<T> _run<T>(
    T fallback,
    Future<T> Function(StoreDatabase db) body,
  ) async {
    if (_closed || ownerId.isEmpty) return fallback;
    final opened = _open();
    final done = Completer<void>();
    _inflight.add(done.future);
    try {
      final db = await opened;
      if (_seen != _erasures) {
        // Another clear() erased the store since this instance opened: never serve or write on it.
        _closed = true;
        unawaited(close());
        return fallback;
      }
      return await body(db);
    } catch (_) {
      return fallback;
    } finally {
      done.complete();
      _inflight.remove(done.future);
    }
  }

  @override
  Future<List<Message>> newest(String conversationId, {int limit = 50}) =>
      _run(const [], (db) async {
        final rows =
            await (db.select(db.messages)
                  ..where((t) => t.conversationId.equals(conversationId))
                  ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
                  ..limit(limit))
                .get();
        return [for (final r in rows.reversed) messageFromRow(r)];
      });

  @override
  Future<List<Message>> older(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) => _run(const [], (db) async {
    final rows =
        await (db.select(db.messages)
              ..where(
                (t) =>
                    t.conversationId.equals(conversationId) &
                    t.createdAt.isSmallerThanValue(
                      before.microsecondsSinceEpoch,
                    ),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(limit))
            .get();
    return [for (final r in rows.reversed) messageFromRow(r)];
  });

  @override
  Future<List<Message>> around(
    String conversationId,
    String messageId, {
    int each = 50,
  }) => _run(const [], (db) async {
    final centre =
        await (db.select(db.messages)..where(
              (t) =>
                  t.id.equals(messageId) &
                  t.conversationId.equals(conversationId),
            ))
            .getSingleOrNull();
    if (centre == null) return const [];
    final before =
        await (db.select(db.messages)
              ..where(
                (t) =>
                    t.conversationId.equals(conversationId) &
                    t.createdAt.isSmallerThanValue(centre.createdAt),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(each))
            .get();
    final after =
        await (db.select(db.messages)
              ..where(
                (t) =>
                    t.conversationId.equals(conversationId) &
                    t.createdAt.isBiggerThanValue(centre.createdAt),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
              ..limit(each))
            .get();
    return [
      for (final r in before.reversed) messageFromRow(r),
      messageFromRow(centre),
      for (final r in after) messageFromRow(r),
    ];
  });

  @override
  Future<void> upsertAll(List<Message> messages) =>
      _run<void>(null, (db) async {
        final stored = [
          for (final m in messages)
            if (!m.isPending) messageToCompanion(m),
        ];
        await db.batch((b) {
          for (final c in stored) {
            b.insert(db.messages, c, onConflict: DoUpdate((_) => c));
          }
        });
      });

  /// An erase since this open began wins: remove the file and key it may have re-created.
  Future<Never> _lostToErase(File file) async {
    await _deleteFiles(file);
    try {
      await _deleteKey();
    } catch (_) {}
    throw StateError('erased while opening');
  }

  Future<StoreDatabase> _create() async {
    final seen = _seen ??= _erasures;
    final file = await _file();
    await file.parent.create(recursive: true);
    final key = await _key();

    Future<StoreDatabase> attempt() async {
      final db = StoreDatabase(
        NativeDatabase.createInBackground(file, setup: _keyed(key)),
      );
      var ok = false;
      try {
        final owner = await (db.select(
          db.meta,
        )..where((t) => t.key.equals('owner_id'))).getSingleOrNull();
        if (owner == null) {
          await db
              .into(db.meta)
              .insert(MetaCompanion.insert(key: 'owner_id', value: ownerId));
        } else if (owner.value != ownerId) {
          throw StateError('other owner');
        }
        ok = true;
        return db;
      } finally {
        if (!ok) await db.close();
      }
    }

    StoreDatabase db;
    try {
      db = await attempt();
    } catch (_) {
      /* wrong key, other owner, or corrupt: start again from nothing */
      await _deleteFiles(file);
      // An erase that came meanwhile must not be answered by a new file.
      if (seen != _erasures) await _lostToErase(file);
      db = await attempt();
    }
    if (seen != _erasures) {
      // A clear() ran while this was opening: the erase wins, remove what was just made.
      await db.close();
      await _lostToErase(file);
    }
    return db;
  }

  @override
  Future<void> reconcilePage(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) => _run<void>(
    null,
    (db) => db.transaction(() async {
      final ids = [for (final m in page) m.id];
      final oldest = page.isEmpty
          ? null
          : page.first.createdAt.microsecondsSinceEpoch;
      // Stored rows the server no longer returns for the range this page covers.
      await (db.delete(db.messages)..where((t) {
            final stale =
                t.conversationId.equals(conversationId) & t.id.isNotIn(ids);
            return reachedStart || oldest == null
                ? stale
                : stale & t.createdAt.isBiggerOrEqualValue(oldest);
          }))
          .go();
      for (final m in page) {
        // one upsert per row, same as upsertAll
        final c = messageToCompanion(m);
        await db.into(db.messages).insert(c, onConflict: DoUpdate((_) => c));
      }
      if (oldest == null) {
        if (reachedStart) {
          await db
              .into(db.syncStates)
              .insertOnConflictUpdate(
                SyncStatesCompanion.insert(
                  conversationId: conversationId,
                  complete: const Value(true),
                ),
              );
        }
        return;
      }
      final newest = page.last.createdAt.microsecondsSinceEpoch;
      final prev =
          await (db.select(db.syncStates)
                ..where((t) => t.conversationId.equals(conversationId)))
              .getSingleOrNull();
      // The old contiguous block still joins this page when it reaches up to the page's oldest row.
      final joined =
          prev != null &&
          prev.newestAt != null &&
          prev.contiguousFrom != null &&
          prev.newestAt! >= oldest;
      final from = reachedStart
          ? oldest
          : (joined ? math.min(prev.contiguousFrom!, oldest) : oldest);
      final complete = reachedStart || (joined && prev.complete);
      await db
          .into(db.syncStates)
          .insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              conversationId: conversationId,
              newestAt: Value(newest),
              contiguousFrom: Value(from),
              complete: Value(complete),
            ),
          );
    }),
  );

  /// Older page from the background fill: lowers contiguousFrom only.
  @override
  Future<void> extendOlder(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  }) => _run<void>(
    null,
    (db) => db.transaction(() async {
      final prev =
          await (db.select(db.syncStates)
                ..where((t) => t.conversationId.equals(conversationId)))
              .getSingleOrNull();
      if (prev == null) return;
      for (final m in page) {
        final c = messageToCompanion(m);
        await db.into(db.messages).insert(c, onConflict: DoUpdate((_) => c));
      }
      if (page.isEmpty) {
        if (reachedStart) {
          await db
              .into(db.syncStates)
              .insertOnConflictUpdate(
                SyncStatesCompanion.insert(
                  conversationId: conversationId,
                  complete: const Value(true),
                ),
              );
        }
        return;
      }
      final oldest = page.first.createdAt.microsecondsSinceEpoch;
      final from = prev.contiguousFrom == null
          ? oldest
          : math.min(prev.contiguousFrom!, oldest);
      await db
          .into(db.syncStates)
          .insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              conversationId: conversationId,
              newestAt: Value(prev.newestAt),
              contiguousFrom: Value(from),
              complete: Value(reachedStart || prev.complete),
            ),
          );
    }),
  );

  @override
  Future<StoredSync?> syncState(String conversationId) =>
      _run<StoredSync?>(null, (db) async {
        final r =
            await (db.select(db.syncStates)
                  ..where((t) => t.conversationId.equals(conversationId)))
                .getSingleOrNull();
        if (r == null) return null;
        DateTime? at(int? v) =>
            v == null ? null : DateTime.fromMicrosecondsSinceEpoch(v);
        return StoredSync(
          newestAt: at(r.newestAt),
          contiguousFrom: at(r.contiguousFrom),
          complete: r.complete,
        );
      });

  @override
  Future<void> remove(String messageId) => _run<void>(null, (db) async {
    await (db.delete(db.messages)..where((t) => t.id.equals(messageId))).go();
  });

  @override
  Future<void> deleteConversation(String conversationId) => _run<void>(
    null,
    (db) => db.transaction(() async {
      await (db.delete(
        db.messages,
      )..where((t) => t.conversationId.equals(conversationId))).go();
      await (db.delete(
        db.syncStates,
      )..where((t) => t.conversationId.equals(conversationId))).go();
      await (db.delete(
        db.conversations,
      )..where((t) => t.id.equals(conversationId))).go();
    }),
  );

  @override
  Future<List<Message>> search(
    String query, {
    String? conversationId,
    int limit = 100,
  }) async {
    if (!isSearchable(query)) return const [];
    // A quoted FTS5 phrase: the trigram index matches it anywhere inside a word.
    final phrase = '"${foldSearch(query.trim()).replaceAll('"', '""')}"';
    return _run<List<Message>>(const [], (db) async {
      final rows = await db
          .customSelect(
            'SELECT m.* FROM messages_fts f JOIN messages m ON m.rowid = f.rowid '
            'WHERE messages_fts MATCH ? AND m.deleted IS NULL'
            '${conversationId == null ? '' : ' AND m.conversation_id = ?'} '
            'ORDER BY m.created_at DESC LIMIT ?',
            variables: [
              Variable.withString(phrase),
              if (conversationId != null) Variable.withString(conversationId),
              Variable.withInt(limit),
            ],
            readsFrom: {db.messages},
          )
          .get();
      return [for (final r in rows) messageFromRow(db.messages.map(r.data))];
    });
  }

  /// Waits for the work already running before closing, so no transaction is
  /// abandoned in the database isolate; work started later waits for the clear.
  @override
  Future<void> clear() {
    _erasures++;
    _closed = true;
    final running = _inflight.toList();
    final pending = _db;
    _db = null;
    final previous = _clearing;
    return _clearing = _clearOnce(previous, running, pending);
  }

  Future<void> _clearOnce(
    Future<void>? previous,
    List<Future<void>> running,
    Future<StoreDatabase>? pending,
  ) async {
    if (previous != null) {
      await previous;
      // A database opened while the earlier clear ran is closed too.
      running = _inflight.toList();
      pending = _db;
      _db = null;
    }
    await Future.wait(running);
    try {
      if (pending != null) await (await pending).close();
    } catch (_) {}
    try {
      await _deleteFiles(await _file());
    } catch (_) {}
    try {
      await _deleteKey();
    } catch (_) {}
  }

  /// Closes this instance (user changed): waits for running work, closes the database, deletes nothing.
  Future<void> close() async {
    _closed = true;
    final pending = _db;
    _db = null;
    await Future.wait(_inflight.toList());
    try {
      if (pending != null) await (await pending).close();
    } catch (_) {}
  }

  @override
  Future<ChangeCursor?> cursor() => _run<ChangeCursor?>(null, (db) async {
    final row = await (db.select(
      db.meta,
    )..where((t) => t.key.equals('change_cursor'))).getSingleOrNull();
    if (row == null) return null;
    final value = row.value;
    final i = value.indexOf('|');
    if (i < 0) return null;
    final a = value.substring(0, i);
    final b = value.substring(i + 1);
    return ChangeCursor(DateTime.fromMicrosecondsSinceEpoch(int.parse(a)), b);
  });

  @override
  Future<Set<String>> conversationIds() =>
      _run<Set<String>>(const {}, (db) async {
        final rows = await db
            .customSelect(
              'SELECT conversation_id AS id FROM messages '
              'UNION SELECT conversation_id FROM sync_state '
              'UNION SELECT id FROM conversations',
              readsFrom: {db.messages, db.syncStates, db.conversations},
            )
            .get();
        return {for (final r in rows) r.read<String>('id')};
      });

  @override
  Future<void> saveCursor(ChangeCursor c) => _run<void>(null, (db) async {
    await db
        .into(db.meta)
        .insertOnConflictUpdate(
          MetaCompanion.insert(
            key: 'change_cursor',
            value: '${c.updatedAt.microsecondsSinceEpoch}|${c.id}',
          ),
        );
  });
}

/// A plain SQLite would ignore PRAGMA key and store everything unencrypted,
/// so refuse to run without the cipher build.
void Function(Database) _keyed(String key) {
  return (raw) {
    raw.execute("PRAGMA key = \"x'$key'\";");
    if (raw.select('PRAGMA cipher;').isEmpty) {
      throw StateError('SQLite3 Multiple Ciphers is not loaded');
    }
  };
}

Future<void> _deleteFiles(File file) async {
  for (final path in [
    file.path,
    '${file.path}-wal',
    '${file.path}-shm',
    '${file.path}-journal',
  ]) {
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone.
    }
  }
}

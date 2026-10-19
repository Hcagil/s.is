import 'dart:io';

import 'package:drift/drift.dart';

import '../../domain/send_queue_store.dart';
import 'drift_message_store.dart';
import 'store_database.dart';

/// The ciphertext a queued send was locked into (base64) and its Olm type (0 pre-key, 1 normal).
final class QueuedCiphertext {
  const QueuedCiphertext(this.ciphertext, this.olmType);

  final String ciphertext;
  final int olmType;
}

/// [SendQueueStore] in the encrypted on-phone store (table send_queue): per member, never synced.
/// Replaces nothing yet; the send path moves onto it later.
final class DriftSendQueueStore implements SendQueueStore {
  /// Creates the store.
  DriftSendQueueStore(this._store);

  final DriftMessageStore _store;

  @override
  Future<List<QueuedRecord>> load(String userId) {
    return _store.run<List<QueuedRecord>>(const [], (db) async {
      final rows =
          await (db.select(db.sendQueueRows)
                ..where((r) => r.userId.equals(userId))
                ..orderBy([(r) => OrderingTerm.asc(r.position)]))
              .get();

      final List<QueuedRecord> result = [];
      for (final row in rows) {
        final records = decodeQueue(row.record);
        for (final r in records) {
          if (_present(r)) {
            result.add(r);
          }
        }
      }

      return result;
    });
  }

  static bool _present(QueuedRecord r) {
    final f = r.file;
    if (f != null) return File(f.path).existsSync();
    final v = r.video;
    if (v != null) return File(v.path).existsSync();
    return r.body.isNotEmpty || r.stickerId != null || r.albumId != null;
  }

  @override
  Future<void> save(String userId, List<QueuedRecord> records) {
    return _store.run<void>(
      null,
      (db) => db.transaction(() async {
        // Read existing rows into a map by id.
        final existing = <String, StoredSendQueueRow>{};
        final rows = await (db.select(
          db.sendQueueRows,
        )..where((r) => r.userId.equals(userId))).get();
        for (final row in rows) {
          existing[row.id] = row;
        }

        // Delete all rows for this user.
        await (db.delete(
          db.sendQueueRows,
        )..where((r) => r.userId.equals(userId))).go();

        // Insert new rows.
        for (int i = 0; i < records.length; i++) {
          final r = records[i];
          final old = existing[r.id];
          await db
              .into(db.sendQueueRows)
              .insert(
                SendQueueRowsCompanion.insert(
                  userId: userId,
                  id: r.id,
                  position: i,
                  record: encodeQueue([r]),
                  ciphertext: Value(old?.ciphertext),
                  olmType: Value(old?.olmType),
                ),
              );
        }
      }),
    );
  }

  @override
  Future<void> clear() {
    return _store.run<void>(null, (db) async {
      await db.delete(db.sendQueueRows).go();
    });
  }

  /// Updates the ciphertext and olmType for a queued send.
  /// Returns true if exactly one row was updated.
  Future<bool> setCiphertext(
    String userId,
    String id,
    String ciphertext,
    int olmType,
  ) {
    return _store.run(false, (db) async {
      final count =
          await (db.update(
            db.sendQueueRows,
          )..where((r) => r.userId.equals(userId) & r.id.equals(id))).write(
            SendQueueRowsCompanion(
              ciphertext: Value(ciphertext),
              olmType: Value(olmType),
            ),
          );
      return count == 1;
    });
  }

  /// Returns the ciphertext and olmType for a queued send, if both are set.
  Future<QueuedCiphertext?> ciphertextOf(String userId, String id) {
    return _store.run<QueuedCiphertext?>(null, (db) async {
      final row =
          await (db.select(db.sendQueueRows)
                ..where((r) => r.userId.equals(userId) & r.id.equals(id)))
              .getSingleOrNull();

      if (row?.ciphertext != null && row?.olmType != null) {
        return QueuedCiphertext(row!.ciphertext!, row.olmType!);
      }
      return null;
    });
  }
}

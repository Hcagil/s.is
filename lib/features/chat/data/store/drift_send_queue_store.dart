import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../domain/send_queue_store.dart';
import 'drift_message_store.dart';
import 'store_database.dart';

/// [SendQueueStore] in the encrypted on-phone store (table send_queue): per member, never synced.
final class DriftSendQueueStore implements SendQueueStore, QueuedCiphertexts {
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
      write: true,
    );
  }

  @override
  Future<void> clear() {
    return _store.run<void>(null, (db) async {
      // Files outside the app's own folders are the member's own and are never deleted.
      final own = await _ownFolders();
      for (final row in await db.select(db.sendQueueRows).get()) {
        for (final r in decodeQueue(row.record)) {
          for (final p in [r.file?.path, r.file?.thumbPath, r.video?.path]) {
            if (p == null) continue;
            // Normalised, and a real folder boundary: neither "<app>/../DCIM/x" nor "<app>-gallery/x" counts as inside the app's folders.
            final clean = path.normalize(p);
            if (!own.any((d) => path.isWithin(d, clean))) continue;
            try {
              await File(clean).delete();
            } catch (_) {}
          }
        }
      }
      await db.delete(db.sendQueueRows).go();
    });
  }

  static Future<List<String>> _ownFolders() async {
    try {
      return [
        (await getTemporaryDirectory()).path,
        (await getApplicationSupportDirectory()).path,
        (await getApplicationDocumentsDirectory()).path,
      ];
    } catch (_) {
      return const [];
    }
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
  @override
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

import 'dart:convert';

import '../../chat/data/store/drift_message_store.dart';
import '../../chat/data/store/store_database.dart';
import '../domain/admin_snapshot.dart';
import '../domain/admin_snapshot_store.dart';

const _key = 'admin_snapshot';

/// Stores the admin snapshot in the [meta] table of the same encrypted
/// database as [DriftMessageStore].
class DriftAdminSnapshotStore implements AdminSnapshotStore {
  DriftAdminSnapshotStore(this._store);

  final DriftMessageStore _store;

  @override
  Future<AdminSavedSnapshot?> load() async =>
      _store.run<AdminSavedSnapshot?>(null, (db) async {
        final metaRow = await (db.select(
          db.meta,
        )..where((m) => m.key.equals(_key))).getSingleOrNull();
        if (metaRow == null) return null;

        try {
          final map = jsonDecode(metaRow.value) as Map<String, Object?>;
          final epoch = map['epoch'] as int?;
          final lastId = map['lastId'] as int?;
          final snapshot = AdminSnapshot.tryFromJson(map['snapshot']);
          if (epoch == null || lastId == null || snapshot == null) {
            await clear();
            return null;
          }
          return AdminSavedSnapshot(
            epoch: epoch,
            lastId: lastId,
            snapshot: snapshot,
          );
        } catch (_) {
          // Corrupt JSON: clear and return null.
          await clear();
          return null;
        }
      });

  @override
  Future<void> save(AdminSavedSnapshot saved) async {
    final json = jsonEncode({
      'epoch': saved.epoch,
      'lastId': saved.lastId,
      'snapshot': saved.snapshot.toJson(),
    });
    try {
      await _store.run(null, (db) async {
        await db
            .into(db.meta)
            .insertOnConflictUpdate(
              MetaCompanion.insert(key: _key, value: json),
            );
      });
    } catch (_) {
      // Best effort: a failed save only costs the instant start.
    }
  }

  @override
  Future<void> clear() async {
    await _store.run(null, (db) async {
      await (db.delete(db.meta)..where((m) => m.key.equals(_key))).go();
    });
  }
}

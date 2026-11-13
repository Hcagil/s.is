import 'dart:convert';

import '../../chat/data/store/drift_message_store.dart';
import '../../chat/data/store/store_database.dart';
import '../domain/admin_seen_store.dart';

const _key = 'admin_seen';

/// Stores which admin items were seen, as ids only, in the meta table of the
/// same encrypted database as the snapshot.
class DriftAdminSeenStore implements AdminSeenStore {
  DriftAdminSeenStore(this._store);

  final DriftMessageStore _store;

  @override
  Future<Map<String, Set<String>>?> load() async =>
      _store.run<Map<String, Set<String>>?>(null, (db) async {
        final metaRow = await (db.select(
          db.meta,
        )..where((m) => m.key.equals(_key))).getSingleOrNull();
        if (metaRow == null) return null;

        try {
          final map = jsonDecode(metaRow.value) as Map<String, Object?>;
          return {
            for (final e in map.entries)
              if (e.value is List)
                e.key: {for (final x in e.value! as List) '$x'},
          };
        } catch (_) {
          // Corrupt JSON: clear and return null.
          await clear();
          return null;
        }
      });

  @override
  Future<void> save(Map<String, Set<String>> seen) async {
    final json = jsonEncode({
      for (final e in seen.entries) e.key: e.value.toList(),
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
      // Best effort: a lost save only shows a number again.
    }
  }

  @override
  Future<void> clear() async {
    await _store.run(null, (db) async {
      await (db.delete(db.meta)..where((m) => m.key.equals(_key))).go();
    });
  }
}

import '../../chat/data/store/drift_message_store.dart';
import '../../chat/data/store/store_database.dart';
import '../domain/key_directory.dart';

/// Stores the olm account pickle in the [meta] table of the same encrypted database as [DriftMessageStore].
class DriftOlmPickleStore implements OlmPickleStore {
  DriftOlmPickleStore(this._store);

  final DriftMessageStore _store;

  @override
  Future<String?> load() {
    return _store.run<String?>(
      null,
      (db) async => (await (db.select(
        db.meta,
      )..where((m) => m.key.equals('olm_account'))).getSingleOrNull())?.value,
    );
  }

  @override
  Future<bool> save(String pickle) {
    return _store.run<bool>(false, (db) async {
      await db
          .into(db.meta)
          .insertOnConflictUpdate(
            MetaCompanion.insert(key: 'olm_account', value: pickle),
          );
      return true;
    });
  }

  @override
  Future<bool> update(Future<String?> Function(String? current) change) {
    return _store.run<bool>(
      false,
      (db) => db.transaction(() async {
        final current = await (db.select(
          db.meta,
        )..where((m) => m.key.equals('olm_account'))).getSingleOrNull();
        final next = await change(current?.value);
        if (next != null) {
          await db
              .into(db.meta)
              .insertOnConflictUpdate(
                MetaCompanion.insert(key: 'olm_account', value: next),
              );
        }
        return true;
      }),
    );
  }
}

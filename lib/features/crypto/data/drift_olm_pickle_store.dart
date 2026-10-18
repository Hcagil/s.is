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
}

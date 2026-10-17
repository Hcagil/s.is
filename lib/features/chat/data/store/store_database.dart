import 'package:drift/drift.dart';

import 'tables.dart';

part 'store_database.g.dart';

/// The on-phone message database (see MessageStore). Schema version 1.
@DriftDatabase(tables: [Messages, Conversations, SyncStates, Meta])
class StoreDatabase extends _$StoreDatabase {
  StoreDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      for (final sql in _ftsStatements) {
        await customStatement(sql);
      }
    },
  );
}

/// Full-text index over the folded body: FTS5 with the trigram tokenizer, so a
/// query of 3+ characters matches anywhere inside a word. External-content table
/// kept in sync by triggers.
const _ftsStatements = <String>[
  "CREATE VIRTUAL TABLE messages_fts USING fts5(body_folded, content='messages', content_rowid='rowid', tokenize='trigram')",
  'CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN INSERT INTO messages_fts(rowid, body_folded) VALUES (new.rowid, new.body_folded); END',
  "CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN INSERT INTO messages_fts(messages_fts, rowid, body_folded) VALUES ('delete', old.rowid, old.body_folded); END",
  "CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN INSERT INTO messages_fts(messages_fts, rowid, body_folded) VALUES ('delete', old.rowid, old.body_folded); INSERT INTO messages_fts(rowid, body_folded) VALUES (new.rowid, new.body_folded); END",
];

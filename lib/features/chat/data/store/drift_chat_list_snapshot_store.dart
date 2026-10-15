import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/chat_list_snapshot_store.dart';
import '../../domain/conversation.dart';
import 'drift_message_store.dart';
import 'store_database.dart';

/// Stores the chat list in the [conversations] table of the same encrypted
/// database as [DriftMessageStore].
class DriftChatListSnapshotStore implements ChatListSnapshotStore {
  DriftChatListSnapshotStore(this._store);

  final DriftMessageStore _store;

  @override
  Future<List<Conversation>?> load(String ownerId) {
    if (ownerId != _store.ownerId) return Future.value(null);
    return _store.run<List<Conversation>?>(null, (db) async {
      final metaRow = await (db.select(
        db.meta,
      )..where((m) => m.key.equals('chat_list_saved'))).getSingleOrNull();
      if (metaRow == null) return null;

      final rows = await (db.select(
        db.conversations,
      )..orderBy([(c) => OrderingTerm.asc(c.sortAt)])).get();
      try {
        return rows.map((row) {
          final json = jsonDecode(row.json) as Map<String, Object?>;
          return Conversation.fromJson(json);
        }).toList();
      } catch (_) {
        // Corrupt JSON: clear and return null.
        await clear();
        return null;
      }
    });
  }

  @override
  Future<void> save(String ownerId, List<Conversation> conversations) {
    if (ownerId != _store.ownerId) return Future.value();
    return _store.run(null, (db) async {
      await db.transaction(() async {
        await db.delete(db.conversations).go();
        final inserts = <ConversationsCompanion>[];
        for (int i = 0; i < conversations.length; i++) {
          final c = conversations[i];
          inserts.add(
            ConversationsCompanion.insert(
              id: c.id,
              json: jsonEncode(c.toJson()),
              sortAt: i,
            ),
          );
        }
        await db.batch((batch) {
          batch.insertAll(db.conversations, inserts);
          batch.insert(
            db.meta,
            MetaCompanion.insert(key: 'chat_list_saved', value: '1'),
            onConflict: DoUpdate(
              (_) => MetaCompanion.insert(key: 'chat_list_saved', value: '1'),
            ),
          );
        });
      });
    });
  }

  @override
  Future<void> clear() {
    return _store.run(null, (db) async {
      await db.transaction(() async {
        await db.delete(db.conversations).go();
        await (db.delete(
          db.meta,
        )..where((m) => m.key.equals('chat_list_saved'))).go();
      });
    });
  }
}

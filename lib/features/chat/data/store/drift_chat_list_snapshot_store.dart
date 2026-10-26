import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/chat_list_snapshot_store.dart';
import '../../domain/conversation.dart';
import 'drift_message_store.dart';
import 'push_feed_writer.dart';
import 'store_database.dart';

/// Stores the chat list in the [conversations] table of the same encrypted
/// database as [DriftMessageStore].
class DriftChatListSnapshotStore implements ChatListSnapshotStore {
  DriftChatListSnapshotStore(this._store);

  final DriftMessageStore _store;

  /// Plain-file chat_list.json for the Android push code (InstantPush.avatarFor): picture paths only, no message text.
  final _feed = PushFeedWriter();

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
  Future<void> save(String ownerId, List<Conversation> conversations) async {
    if (ownerId != _store.ownerId) return;
    final epoch = _feed.epoch;
    final wrote = await _store.run(false, (db) async {
      await db.transaction(() async {
        await db.delete(db.conversations).go();
        await (db.delete(db.pushInbox)..where(
              (t) => t.conversationId.isNotIn([
                for (final c in conversations) c.id,
              ]),
            ))
            .go();
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
      return true;
    });
    // No feed for a list the store did not take (closed, erased or failed), nor
    // for a save that began before any feed clear: an erase that started after
    // this save began always wins, on any store instance.
    if (wrote && _feed.epoch == epoch) {
      await _feed.save(ownerId, conversations);
    }
  }

  @override
  Future<void> clear() async {
    await _feed.clear();
    await _store.run(null, (db) async {
      await db.transaction(() async {
        await db.delete(db.conversations).go();
        await db.delete(db.pushInbox).go();
        await (db.delete(
          db.meta,
        )..where((m) => m.key.equals('chat_list_saved'))).go();
      });
    });
  }
}

import 'package:drift/drift.dart';

import '../../domain/reaction_store.dart';
import 'drift_message_store.dart';
import 'store_database.dart';

/// Stores opened locked reactions in the [reactionPlains] table of the same
/// encrypted database as [DriftMessageStore]; erased with it on sign-out.
final class DriftReactionStore implements ReactionStore {
  DriftReactionStore(this._store);

  final DriftMessageStore _store;

  @override
  Future<String?> emojiOf(String messageId, String userId, String sealed) {
    return _store.run<String?>(null, (db) async {
      final row =
          await (db.select(db.reactionPlains)..where(
                (t) =>
                    t.messageId.equals(messageId) &
                    t.userId.equals(userId) &
                    t.sealed.equals(sealed),
              ))
              .getSingleOrNull();
      return row?.emoji;
    });
  }

  @override
  Future<void> put(
    String messageId,
    String userId,
    String sealed,
    String emoji,
  ) {
    return _store.run<void>(null, (db) async {
      await db
          .into(db.reactionPlains)
          .insertOnConflictUpdate(
            ReactionPlainsCompanion.insert(
              messageId: messageId,
              userId: userId,
              sealed: sealed,
              emoji: emoji,
              savedAt: DateTime.now().microsecondsSinceEpoch,
            ),
          );
    }, write: true);
  }

  @override
  Future<Map<String, int>> usageOf(String userId, {int limit = 300}) {
    return _store.run<Map<String, int>>(const {}, (db) async {
      final rows =
          await (db.select(db.reactionPlains)
                ..where((t) => t.userId.equals(userId))
                ..orderBy([
                  (t) => OrderingTerm(
                    expression: t.savedAt,
                    mode: OrderingMode.desc,
                  ),
                ])
                ..limit(limit))
              .get();
      final usage = <String, int>{};
      for (final row in rows) {
        usage[row.emoji] = (usage[row.emoji] ?? 0) + 1;
      }
      return usage;
    });
  }
}

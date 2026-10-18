import 'package:drift/drift.dart';

import '../../domain/read_mark_store.dart';
import '../../domain/read_marks.dart';
import 'drift_message_store.dart';
import 'store_database.dart';

/// Stores read marks in the [readMarks] table of the same encrypted database
/// as [DriftMessageStore]; erased with it on sign-out.
final class DriftReadMarkStore implements ReadMarkStore {
  DriftReadMarkStore(this._store);

  final DriftMessageStore _store;

  static DateTime? _at(int? us) =>
      us == null ? null : DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true);

  @override
  Future<List<ReadMark>> load(String conversationId) {
    return _store.run<List<ReadMark>>(const [], (db) async {
      final rows = await (db.select(
        db.readMarks,
      )..where((t) => t.conversationId.equals(conversationId))).get();
      return [
        for (final r in rows)
          ReadMark(
            userId: r.userId,
            shares: r.shares,
            readAt: _at(r.readAt),
            deliveredAt: _at(r.deliveredAt),
          ),
      ];
    });
  }

  @override
  Future<void> save(String conversationId, List<ReadMark> marks) {
    return _store.run<void>(null, (db) async {
      await db.transaction(() async {
        await (db.delete(
          db.readMarks,
        )..where((t) => t.conversationId.equals(conversationId))).go();
        await db.batch((batch) {
          batch.insertAll(db.readMarks, [
            for (final m in marks)
              ReadMarksCompanion.insert(
                conversationId: conversationId,
                userId: m.userId,
                shares: m.shares,
                readAt: Value(m.readAt?.microsecondsSinceEpoch),
                deliveredAt: Value(m.deliveredAt?.microsecondsSinceEpoch),
              ),
          ]);
        });
      });
    });
  }
}

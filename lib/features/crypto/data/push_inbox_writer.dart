import 'dart:io' show sleep;

import 'package:sqlite3/sqlite3.dart';

/// Saves a message the notification opened into push_inbox of the encrypted store. Returns a fixed reason code, never text, ids or keys: 'saved', 'inbox_budget' (less than 500 ms of push time left), 'inbox_old_schema' (user_version < 5: the app has not migrated yet), 'inbox_busy' (the store stayed locked until the cap), 'inbox_skip' (the message or its chat was not eligible: the real row exists, or the chat is not in the store), 'inbox_error'. Never throws, never creates a file or a table, never deletes or recreates anything.
String writePushInbox({
  required String path,
  required String keyHex,
  required String conversationId,
  required String messageId,
  required String peerUserId,
  required String body,
  required String sealed,
  required int receivedAtMicros,
  required int budgetMs,
}) {
  if (budgetMs < 500) return 'inbox_budget';

  final cap = (budgetMs - 250).clamp(0, 500);
  final clock = Stopwatch()..start();

  while (true) {
    try {
      return _write(
        path: path,
        keyHex: keyHex,
        conversationId: conversationId,
        messageId: messageId,
        peerUserId: peerUserId,
        body: body,
        sealed: sealed,
        receivedAtMicros: receivedAtMicros,
      );
    } on SqliteException catch (e) {
      // PRAGMA busy_timeout alone fails at once on this build, hence the manual retry.
      final busy = e.resultCode == 5 || e.resultCode == 6;
      if (!busy) return 'inbox_error';
      if (clock.elapsedMilliseconds >= cap) return 'inbox_busy';
      sleep(const Duration(milliseconds: 25));
    } catch (_) {
      return 'inbox_error';
    }
  }
}

String _write({
  required String path,
  required String keyHex,
  required String conversationId,
  required String messageId,
  required String peerUserId,
  required String body,
  required String sealed,
  required int receivedAtMicros,
}) {
  final db = sqlite3.open(path, mode: OpenMode.readWrite); // never creates
  try {
    db.execute('PRAGMA key = "x\'$keyHex\'";');
    db.execute('PRAGMA busy_timeout = 100;');
    if (db.select('PRAGMA cipher;').isEmpty) return 'inbox_error';
    final version = db.select('PRAGMA user_version;').first.values.first as int;
    if (version < 5) return 'inbox_old_schema';
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute(
        'INSERT OR IGNORE INTO push_inbox(message_id, conversation_id, sender_id, body, sealed, received_at) SELECT ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM messages WHERE id = ?) AND EXISTS (SELECT 1 FROM conversations WHERE id = ?);',
        [
          messageId,
          conversationId,
          peerUserId,
          body,
          sealed,
          receivedAtMicros,
          messageId,
          conversationId,
        ],
      );
      final saved = db.updatedRows == 1;
      db.execute('COMMIT;');
      return saved ? 'saved' : 'inbox_skip';
    } catch (_) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {}
      rethrow;
    }
  } finally {
    db.close();
  }
}

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// One stored Olm session row (pickle is still encrypted with the pickle key).
final class PeekSession {
  const PeekSession({
    required this.sessionId,
    required this.peerUserId,
    required this.peerIdentityKey,
    required this.pickle,
  });

  final String sessionId;
  final String peerUserId;
  final String peerIdentityKey;
  final String pickle;
}

/// What a notification reads from the store: owner, the conversation's peer, a stored plaintext, the account pickle and the peer's sessions.
final class PeekRows {
  const PeekRows({
    required this.ownerId,
    required this.peerUserId,
    required this.storedBody,
    required this.account,
    required this.sessions,
  });

  /// Meta key 'owner_id'.
  final String? ownerId;

  /// The conversation's other member id, null if unknown.
  final String? peerUserId;

  /// messages.body of the message id; null if no such row or the row is deleted.
  final String? storedBody;

  /// Meta key 'olm_account' (account pickle).
  final String? account;

  /// Sessions of [peerUserId], newest lastUsedAt first; empty if [peerUserId] is null.
  final List<PeekSession> sessions;
}

/// Null on ANY failure (missing file, wrong key, busy, corrupt, no cipher build). Never throws, never writes.
PeekRows? readPeekRows({
  required String path,
  required String keyHex,
  required String conversationId,
  required String messageId,
}) {
  try {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      db.execute('PRAGMA key = "x\'$keyHex\'";');
      db.execute('PRAGMA busy_timeout = 1000;');
      db.execute('PRAGMA query_only = 1;');
      if (db.select('PRAGMA cipher;').isEmpty) return null;

      db.execute('BEGIN;');
      try {
        String? meta(String key) {
          final r = db.select('SELECT value FROM meta WHERE key = ?;', [key]);
          return r.isEmpty ? null : r.first['value'] as String;
        }

        String? peerUserId;
        final conv = db.select('SELECT json FROM conversations WHERE id = ?;', [
          conversationId,
        ]);
        if (conv.isNotEmpty) {
          try {
            final json = jsonDecode(conv.first['json'] as String);
            final other = json is Map ? json['other'] : null;
            final id = other is Map ? other['id'] : null;
            if (id is String) peerUserId = id;
          } on FormatException {
            // An unreadable snapshot means an unknown peer, not a failure.
          }
        }

        final msg = db.select(
          'SELECT body, deleted FROM messages WHERE id = ?;',
          [messageId],
        );
        final storedBody = msg.isNotEmpty && msg.first['deleted'] == null
            ? msg.first['body'] as String
            : null;

        final sessions = peerUserId == null
            ? <PeekSession>[]
            : [
                for (final row in db.select(
                  'SELECT session_id, peer_user_id, peer_identity_key, pickle '
                  'FROM olm_sessions WHERE peer_user_id = ? '
                  'ORDER BY last_used_at DESC;',
                  [peerUserId],
                ))
                  PeekSession(
                    sessionId: row['session_id'] as String,
                    peerUserId: row['peer_user_id'] as String,
                    peerIdentityKey: row['peer_identity_key'] as String,
                    pickle: row['pickle'] as String,
                  ),
              ];

        return PeekRows(
          ownerId: meta('owner_id'),
          peerUserId: peerUserId,
          storedBody: storedBody,
          account: meta('olm_account'),
          sessions: sessions,
        );
      } finally {
        db.execute('COMMIT;');
      }
    } finally {
      db.close();
    }
  } catch (_) {
    return null;
  }
}

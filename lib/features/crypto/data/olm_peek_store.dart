import 'dart:convert';
import 'dart:io' show sleep;

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
    this.keyPeers = const [],
    this.peerName,
    this.storedSenderId,
  });

  /// Meta key 'owner_id'.
  final String? ownerId;

  /// The conversation's other member id, null if unknown.
  final String? peerUserId;

  /// The other member's display name from the phone's own copy of the chat (json other.name), null if unknown or empty.
  final String? peerName;

  /// messages.body of the message id; null if no such row or the row is deleted.
  final String? storedBody;

  /// messages.sender_id of that same row; null when no row or deleted.
  final String? storedSenderId;

  /// Meta key 'olm_account' (account pickle).
  final String? account;

  /// Sessions of [peerUserId], newest lastUsedAt first; empty if [peerUserId] is null.
  final List<PeekSession> sessions;

  /// peer_user_id of every stored session whose peer_identity_key equals the senderKey given to readPeekRows; empty when none or no senderKey.
  final List<String> keyPeers;
}

/// Null on ANY failure (missing file, wrong key, busy, corrupt, no cipher build). Never throws, never writes.
PeekRows? readPeekRows({
  required String path,
  required String keyHex,
  required String conversationId,
  required String messageId,
  String? senderKey,
  String? senderId,
}) {
  // A busy or locked store (SQLITE_BUSY 5, SQLITE_LOCKED 6) is retried for at most about 1 s in total; PRAGMA busy_timeout alone fails at once on this build.
  final clock = Stopwatch()..start();
  while (true) {
    try {
      return _readPeekRows(
        path,
        keyHex,
        conversationId,
        messageId,
        senderKey,
        senderId,
      );
    } on SqliteException catch (e) {
      final busy = e.resultCode == 5 || e.resultCode == 6;
      if (!busy || clock.elapsedMilliseconds >= 1000) return null;
      sleep(const Duration(milliseconds: 25));
    } catch (_) {
      return null;
    }
  }
}

PeekRows? _readPeekRows(
  String path,
  String keyHex,
  String conversationId,
  String messageId,
  String? senderKey,
  String? senderId,
) {
  {
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
        String? peerName;
        final conv = db.select('SELECT json FROM conversations WHERE id = ?;', [
          conversationId,
        ]);
        if (conv.isNotEmpty) {
          try {
            final json = jsonDecode(conv.first['json'] as String);
            final other = json is Map ? json['other'] : null;
            final id = other is Map ? other['id'] : null;
            if (id is String) peerUserId = id;
            final name = other is Map ? other['name'] : null;
            if (name is String && name.isNotEmpty) peerName = name;
          } on FormatException {
            // An unreadable snapshot means an unknown peer, not a failure.
          }
        }

        final msg = db.select(
          'SELECT body, deleted, sender_id FROM messages WHERE id = ? AND conversation_id = ?;',
          [messageId, conversationId],
        );
        final storedBody = msg.isNotEmpty && msg.first['deleted'] == null
            ? msg.first['body'] as String
            : null;
        final storedSenderId = msg.isNotEmpty && msg.first['deleted'] == null
            ? msg.first['sender_id'] as String
            : null;

        final lookupPeer = peerUserId ?? senderId;
        final sessions = lookupPeer == null
            ? <PeekSession>[]
            : [
                for (final row in db.select(
                  'SELECT session_id, peer_user_id, peer_identity_key, pickle '
                  'FROM olm_sessions WHERE peer_user_id = ? '
                  'ORDER BY last_used_at DESC;',
                  [lookupPeer],
                ))
                  PeekSession(
                    sessionId: row['session_id'] as String,
                    peerUserId: row['peer_user_id'] as String,
                    peerIdentityKey: row['peer_identity_key'] as String,
                    pickle: row['pickle'] as String,
                  ),
              ];

        // The stored sessions that already carry this key, for any peer (the peek refuses a key that belongs to someone else).
        final keyPeers = senderKey == null
            ? <String>[]
            : [
                for (final row in db.select(
                  'SELECT DISTINCT peer_user_id FROM olm_sessions '
                  'WHERE peer_identity_key = ?;',
                  [senderKey],
                ))
                  row['peer_user_id'] as String,
              ];

        return PeekRows(
          ownerId: meta('owner_id'),
          peerUserId: peerUserId,
          peerName: peerName,
          storedBody: storedBody,
          storedSenderId: storedSenderId,
          account: meta('olm_account'),
          sessions: sessions,
          keyPeers: keyPeers,
        );
      } finally {
        db.execute('COMMIT;');
      }
    } finally {
      db.close();
    }
  }
}

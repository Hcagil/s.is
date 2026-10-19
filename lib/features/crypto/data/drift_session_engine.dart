import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/failure.dart';
import '../../chat/data/store/drift_message_store.dart';
import '../../chat/data/store/store_database.dart';
import '../../chat/domain/message.dart' show foldSearch;
import '../domain/key_directory.dart';
import '../domain/key_engine.dart';
import '../domain/session_engine.dart';

/// Olm sessions in the encrypted on-phone store: every call that changes state writes its session pickle, the account pickle when it changed, and the plaintext in ONE database transaction.
final class DriftSessionEngine implements SessionEngine {
  DriftSessionEngine({
    required this._store,
    required this._keys,
    required this._sessions,
    required this._pickleKey,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DriftMessageStore _store;
  final KeyEngine _keys;
  final SessionKeyEngine _sessions;
  final PickleKeyStore _pickleKey;
  final DateTime Function() _now;

  Future<Result<T>> _tx<T>(
    Future<Result<T>> Function(StoreDatabase db, List<int> key) body,
  ) async {
    final List<int> key;
    try {
      key = await _pickleKey.loadOrCreate();
    } catch (_) {
      return Err<T>(const SessionStoreFailure());
    }
    // body returns Err before it writes anything; a throw rolls the transaction back.
    return _store.run<Result<T>>(
      Err<T>(const SessionStoreFailure()),
      (db) => db.transaction(() => body(db, key)),
    );
  }

  Future<SessionAccount?> _account(StoreDatabase db, List<int> key) async {
    final row = await (db.select(
      db.meta,
    )..where((m) => m.key.equals('olm_account'))).getSingleOrNull();
    if (row == null) return null;
    try {
      return await _sessions.restoreSessionAccount(row.value, key);
    } on KeyEngineException {
      return null;
    }
  }

  Future<List<StoredOlmSessionRow>> _sessionsOf(
    StoreDatabase db,
    String peerUserId,
  ) {
    return (db.select(db.olmSessions)
          ..where((t) => t.peerUserId.equals(peerUserId))
          ..orderBy([(t) => OrderingTerm.desc(t.lastUsedAt)]))
        .get();
  }

  Future<void> _putSession(
    StoreDatabase db,
    List<int> key,
    KeySession s, {
    required String peerUserId,
    required String peerIdentityKey,
  }) async {
    await db
        .into(db.olmSessions)
        .insertOnConflictUpdate(
          OlmSessionsCompanion.insert(
            sessionId: s.sessionId,
            peerUserId: peerUserId,
            peerIdentityKey: peerIdentityKey,
            pickle: s.pickle(key),
            lastUsedAt: _now().microsecondsSinceEpoch,
          ),
        );
  }

  Future<void> _putAccount(
    StoreDatabase db,
    List<int> key,
    SessionAccount a,
  ) async {
    await db
        .into(db.meta)
        .insertOnConflictUpdate(
          MetaCompanion.insert(key: 'olm_account', value: a.pickle(key)),
        );
  }

  Future<void> _savePlaintext(StoreDatabase db, PlaintextSave? save) async {
    if (save == null) return;
    await (db.update(
      db.messages,
    )..where((t) => t.id.equals(save.messageId))).write(
      MessagesCompanion(
        body: Value(save.plaintext),
        bodyFolded: Value(foldSearch(save.plaintext)),
      ),
    );
  }

  @override
  Future<bool> hasSession(String peerUserId) => _store.run<bool>(
    false,
    (db) async => (await _sessionsOf(db, peerUserId)).isNotEmpty,
  );

  @override
  Future<Result<String>> createOutbound(
    String peerUserId,
    ClaimedKeys keys,
  ) async {
    if (!await _keys.verifyDevice(peerUserId, keys)) {
      return const Err(DeviceKeysFailure());
    }
    return _tx<String>((db, key) async {
      final account = await _account(db, key);
      if (account == null) return const Err(SessionStoreFailure());
      final KeySession session;
      try {
        session = account.createOutbound(keys.identityKey, keys.oneTimeKey);
      } on KeyEngineException {
        return const Err(DeviceKeysFailure());
      }
      await _putSession(
        db,
        key,
        session,
        peerUserId: peerUserId,
        peerIdentityKey: keys.identityKey,
      );
      return Ok(session.sessionId);
    });
  }

  @override
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    PlaintextSave? save,
  }) {
    return _tx<LockedText>((db, key) async {
      final rows = await _sessionsOf(db, peerUserId);
      if (rows.isEmpty) return const Err(SessionPendingFailure());
      final row = rows.first; // newest used
      final KeySession session;
      final OlmCipher cipher;
      try {
        session = await _sessions.restoreSession(row.pickle, key);
        cipher = session.encrypt(utf8.encode(plaintext));
      } on KeyEngineException {
        return const Err(SessionStoreFailure());
      }
      await _putSession(
        db,
        key,
        session,
        peerUserId: peerUserId,
        peerIdentityKey: row.peerIdentityKey,
      );
      await _savePlaintext(db, save);
      return Ok(
        LockedText(
          ciphertext: base64.encode(cipher.body),
          olmType: cipher.type,
          sessionId: session.sessionId,
        ),
      );
    });
  }

  OlmCipher? _parse(String ciphertext, int olmType) {
    try {
      return OlmCipher(olmType, base64.decode(ciphertext));
    } on FormatException {
      return null;
    }
  }

  String? _text(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Tries [rows] in the given order; the first session that opens [cipher] is saved (with its new state) and the plaintext returned. Nothing is written on Err.
  Future<Result<String>> _tryRows(
    StoreDatabase db,
    List<int> key,
    List<StoredOlmSessionRow> rows,
    OlmCipher cipher,
    PlaintextSave? save,
  ) async {
    for (final row in rows) {
      final KeySession session;
      final List<int> plain;
      try {
        session = await _sessions.restoreSession(row.pickle, key);
        plain = session.decrypt(cipher);
      } on KeyEngineException {
        continue;
      }
      final text = _text(plain);
      if (text == null) return const Err(UnreadableMessageFailure());
      await _putSession(
        db,
        key,
        session,
        peerUserId: row.peerUserId,
        peerIdentityKey: row.peerIdentityKey,
      );
      await _savePlaintext(db, save);
      return Ok(text);
    }
    return const Err(UnreadableMessageFailure());
  }

  Future<Result<String>> _createInbound(
    String peerUserId,
    String peerIdentityKey,
    OlmCipher cipher,
    PlaintextSave? save,
  ) async {
    final String id;
    try {
      id = await _sessions.preKeySessionId(cipher);
    } on KeyEngineException {
      return const Err(UnreadableMessageFailure());
    }
    return _tx<String>((db, key) async {
      final existing = await (db.select(
        db.olmSessions,
      )..where((t) => t.sessionId.equals(id))).getSingleOrNull();
      if (existing != null) {
        if (existing.peerUserId != peerUserId) {
          return const Err(UnreadableMessageFailure());
        }
        return _tryRows(db, key, [existing], cipher, save);
      }
      final account = await _account(db, key);
      if (account == null) return const Err(SessionStoreFailure());
      final InboundSession inbound;
      try {
        inbound = account.createInbound(peerIdentityKey, cipher);
      } on KeyEngineException {
        return const Err(UnreadableMessageFailure());
      }
      final text = _text(inbound.plaintext);
      if (text == null) return const Err(UnreadableMessageFailure());
      await _putSession(
        db,
        key,
        inbound.session,
        peerUserId: peerUserId,
        peerIdentityKey: peerIdentityKey,
      );
      await _putAccount(db, key, account);
      await _savePlaintext(db, save);
      return Ok(text);
    });
  }

  @override
  Future<Result<String>> createInbound({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) {
    final cipher = _parse(ciphertext, olmType);
    if (cipher == null || olmType != 0) {
      return Future.value(const Err(UnreadableMessageFailure()));
    }
    return _createInbound(peerUserId, peerIdentityKey, cipher, save);
  }

  @override
  Future<Result<String>> decrypt({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  }) {
    final cipher = _parse(ciphertext, olmType);
    if (cipher == null || (olmType != 0 && olmType != 1)) {
      return Future.value(const Err(UnreadableMessageFailure()));
    }
    if (olmType == 0) {
      return _createInbound(peerUserId, peerIdentityKey, cipher, save);
    }
    return _tx<String>((db, key) async {
      final rows = await _sessionsOf(db, peerUserId);
      if (rows.isEmpty) return const Err(SessionPendingFailure());
      return _tryRows(db, key, rows, cipher, save);
    });
  }
}

import 'package:drift/drift.dart';

import '../../chat/data/store/drift_message_store.dart';
import '../../chat/data/store/store_database.dart';
import '../domain/key_directory.dart';
import '../domain/key_engine.dart';
import '../domain/security_code_store.dart';

/// Returns the meta key for a verified peer.
String verifiedMetaKey(String peerUserId) => 'verified:$peerUserId';

/// Returns the meta key for a key change of a peer.
String keyChangeMetaKey(String peerUserId) => 'keychange:$peerUserId';

/// Encodes a key change timestamp and verification status.
String encodeKeyChange(DateTime at, bool wasVerified) =>
    '${at.microsecondsSinceEpoch}|${wasVerified ? 1 : 0}';

/// Stores security codes and chat memory in the [meta] table of the same encrypted database as [DriftMessageStore].
class DriftSecurityCodeStore implements SecurityCodeStore, CipherChatMemory {
  DriftSecurityCodeStore({
    required this._store,
    required this._sessions,
    required this._pickleKey,
  });

  final DriftMessageStore _store;
  final SessionKeyEngine _sessions;
  final PickleKeyStore _pickleKey;

  @override
  Future<OwnKeys?> ownKeys() {
    return _store.run<OwnKeys?>(null, (db) async {
      final pickle = (await (db.select(
        db.meta,
      )..where((m) => m.key.equals('olm_account'))).getSingleOrNull())?.value;
      if (pickle == null) return null;
      try {
        final key = await _pickleKey.loadOrCreate();
        final account = await _sessions.restoreSessionAccount(pickle, key);
        return OwnKeys(
          curve25519: account.identityKey,
          ed25519: account.signingKey,
        );
      } on KeyEngineException {
        return null;
      }
    });
  }

  @override
  Future<String?> sessionPeerKey(String peerUserId) {
    return _store.run<String?>(null, (db) async {
      final row =
          await (db.select(db.olmSessions)
                ..where((s) => s.peerUserId.equals(peerUserId))
                ..orderBy([(s) => OrderingTerm.desc(s.lastUsedAt)])
                ..limit(1))
              .getSingleOrNull();
      return row?.peerIdentityKey;
    });
  }

  @override
  Future<VerifiedKeys?> verified(String peerUserId) {
    return _store.run<VerifiedKeys?>(null, (db) async {
      final row =
          await (db.select(db.meta)
                ..where((m) => m.key.equals(verifiedMetaKey(peerUserId))))
              .getSingleOrNull();
      if (row == null) return null;
      final parts = row.value.split('|');
      if (parts.length != 2 || parts.any((p) => p.isEmpty)) return null;
      return VerifiedKeys(curve25519: parts[0], ed25519: parts[1]);
    });
  }

  @override
  Future<void> markVerified(String peerUserId, VerifiedKeys keys) {
    return _store.run<void>(null, (db) async {
      await db
          .into(db.meta)
          .insertOnConflictUpdate(
            MetaCompanion.insert(
              key: verifiedMetaKey(peerUserId),
              value: '${keys.curve25519}|${keys.ed25519}',
            ),
          );
    });
  }

  @override
  Future<void> clearVerified(String peerUserId) {
    return _store.run<void>(null, (db) async {
      await (db.delete(
        db.meta,
      )..where((m) => m.key.equals(verifiedMetaKey(peerUserId)))).go();
    });
  }

  @override
  Future<KeyChange?> keyChange(String peerUserId) {
    return _store.run<KeyChange?>(null, (db) async {
      final row =
          await (db.select(db.meta)
                ..where((m) => m.key.equals(keyChangeMetaKey(peerUserId))))
              .getSingleOrNull();
      if (row == null) return null;
      final parts = row.value.split('|');
      if (parts.length != 2) return null;
      final micros = int.tryParse(parts[0]);
      if (micros == null || (parts[1] != '0' && parts[1] != '1')) return null;
      return KeyChange(
        at: DateTime.fromMicrosecondsSinceEpoch(micros),
        wasVerified: parts[1] == '1',
      );
    });
  }

  @override
  Future<DateTime?> heldSince(String conversationId) {
    return _store.run<DateTime?>(null, (db) async {
      final row =
          await (db.select(db.meta)
                ..where((m) => m.key.equals(heldMetaKey(conversationId))))
              .getSingleOrNull();
      final micros = row == null ? null : int.tryParse(row.value);
      return micros == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(micros);
    });
  }

  @override
  Future<void> markHeld(String conversationId, DateTime at) {
    return _store.run<void>(null, (db) async {
      await db.transaction(() async {
        final row =
            await (db.select(db.meta)
                  ..where((m) => m.key.equals(heldMetaKey(conversationId))))
                .getSingleOrNull();
        final old = row == null ? null : int.tryParse(row.value);
        if (old != null && old <= at.microsecondsSinceEpoch) return;
        await db
            .into(db.meta)
            .insertOnConflictUpdate(
              MetaCompanion.insert(
                key: heldMetaKey(conversationId),
                value: at.microsecondsSinceEpoch.toString(),
              ),
            );
      });
    });
  }
}

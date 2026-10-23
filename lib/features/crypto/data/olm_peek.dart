import 'dart:convert';

import '../../chat/domain/encrypted_message_repository.dart';
import '../../chat/domain/message_envelope.dart';
import '../domain/key_engine.dart';
import 'olm_key_engine.dart';
import 'olm_peek_store.dart';

/// Decrypts a message using session data from [rows] without persisting the result. [onFail] gets a fixed reason code (never text, ids or keys) when it returns null.
Future<String?> peekDecrypt({
  required PeekRows rows,
  required List<int> pickleKey,
  required String messageId,
  required String ciphertext,
  required int olmType,
  SessionKeyEngine? engine,
  void Function(String reason)? onFail,
}) async {
  try {
    final peer = rows.peerUserId;
    if (peer == null) {
      onFail?.call('no_peer');
      return null;
    }

    if (olmType != 0 && olmType != 1) {
      onFail?.call('decrypt_fail');
      return null;
    }
    final cipher = OlmCipher(olmType, base64.decode(ciphertext));

    engine ??= OlmKeyEngine();

    if (olmType == 1) {
      for (final s in rows.sessions) {
        if (s.peerUserId != peer) continue;
        try {
          final session = await engine.restoreSession(s.pickle, pickleKey);
          final plain = session.decrypt(cipher);
          final text = decodeEnvelope(utf8.decode(plain), messageId);
          if (text == null) onFail?.call('decrypt_fail');
          return text?.text;
        } on KeyEngineException {
          continue;
        }
      }
      onFail?.call(rows.sessions.isEmpty ? 'no_session' : 'decrypt_fail');
      return null;
    } else {
      final id = await engine.preKeySessionId(cipher);
      final session = rows.sessions.where((s) => s.sessionId == id).firstOrNull;
      if (session != null) {
        if (session.peerUserId != peer) {
          onFail?.call('decrypt_fail');
          return null;
        }
        final restored = await engine.restoreSession(session.pickle, pickleKey);
        final plain = restored.decrypt(cipher);
        final text = decodeEnvelope(utf8.decode(plain), messageId);
        if (text == null) onFail?.call('decrypt_fail');
        return text?.text;
      } else {
        if (rows.sessions.isEmpty || rows.account == null) {
          onFail?.call('no_session');
          return null;
        }
        final identityKey = rows.sessions.first.peerIdentityKey;
        final account = await engine.restoreSessionAccount(
          rows.account!,
          pickleKey,
        );
        final inbound = account.createInbound(identityKey, cipher);
        final plain = inbound.plaintext;
        final text = decodeEnvelope(utf8.decode(plain), messageId);
        if (text == null) onFail?.call('decrypt_fail');
        return text?.text;
      }
    }
  } catch (e) {
    onFail?.call('other:${e.runtimeType}');
    return null;
  }
}

/// Reads peek rows and decrypts a message using them without persisting the result.
Future<String?> peekEncryptedText({
  required String storePath,
  required String storeKeyHex,
  required List<int> pickleKey,
  required String ownerId,
  required String conversationId,
  required String messageId,
  required String ciphertext,
  required int olmType,
  void Function(String reason)? onFail,
}) async {
  final rows = readPeekRows(
    path: storePath,
    keyHex: storeKeyHex,
    conversationId: conversationId,
    messageId: messageId,
  );
  if (rows == null) {
    onFail?.call('rows_null');
    return null;
  }
  if (rows.ownerId != ownerId) {
    onFail?.call('owner_mismatch');
    return null;
  }
  if (rows.storedBody != null && !isLockedPlaceholder(rows.storedBody!)) {
    return rows.storedBody;
  }
  return peekDecrypt(
    rows: rows,
    pickleKey: pickleKey,
    messageId: messageId,
    ciphertext: ciphertext,
    olmType: olmType,
    onFail: onFail,
  );
}

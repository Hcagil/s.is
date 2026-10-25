import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../chat/domain/encrypted_message_repository.dart';
import '../../chat/domain/message_envelope.dart';
import '../domain/key_engine.dart';
import 'olm_key_engine.dart';
import 'olm_peek_store.dart';
import 'push_inbox_writer.dart';

// Shapes of the sender key (43-char base64) and id (uuid) a pre-key push carries.
final _senderKeyShape = RegExp(r'^[A-Za-z0-9+/]{43}$');
final _uuidShape = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Decrypts a message using session data from [rows] without persisting the result. [onFail] gets a fixed reason code (never text, ids or keys) when it returns null.
/// [onStoredKey] is called when the text was opened by a session, or a peer key, already stored on the phone (not by the push's own [senderKey]); only then may the text be saved by the push.
/// [senderKey] and [senderId] (from a pre-key push) are used only for olmType 0 with no stored session of that peer; they are never returned or logged.
Future<String?> peekDecrypt({
  required PeekRows rows,
  required List<int> pickleKey,
  required String messageId,
  required String ciphertext,
  required int olmType,
  SessionKeyEngine? engine,
  void Function(String reason)? onFail,
  String? senderKey,
  String? senderId,
  void Function()? onStoredKey,
}) async {
  try {
    final peer = rows.peerUserId ?? (olmType == 0 ? senderId : null);
    if (peer == null) {
      onFail?.call('no_peer');
      return null;
    }
    // The push names someone other than the chat's peer: refuse.
    if (senderId != null &&
        rows.peerUserId != null &&
        senderId != rows.peerUserId) {
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
          if (text == null) {
            onFail?.call('decrypt_fail');
          } else {
            onStoredKey?.call();
          }
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
        final List<int> plain;
        try {
          plain = restored.decrypt(cipher);
        } on KeyEngineException {
          onFail?.call('decrypt_fail');
          return null;
        }
        final text = decodeEnvelope(utf8.decode(plain), messageId);
        if (text == null) {
          onFail?.call('decrypt_fail');
        } else {
          onStoredKey?.call();
        }
        return text?.text;
      } else {
        if (rows.account == null) {
          onFail?.call('no_session');
          return null;
        }
        final String identityKey;
        if (rows.sessions.isNotEmpty) {
          if (rows.sessions.first.peerUserId != peer) {
            onFail?.call('decrypt_fail');
            return null;
          }
          // A stored session of this peer wins; the push's key is ignored (a key change goes through the app).
          identityKey = rows.sessions.first.peerIdentityKey;
        } else if (senderKey == null || senderId == null) {
          onFail?.call('no_session');
          return null;
        } else if (!_senderKeyShape.hasMatch(senderKey) ||
            !_uuidShape.hasMatch(senderId) ||
            senderId != peer ||
            rows.keyPeers.any((p) => p != peer)) {
          // Bad shape, or the key is already stored for another person.
          onFail?.call('decrypt_fail');
          return null;
        } else {
          identityKey = senderKey;
        }
        final account = await engine.restoreSessionAccount(
          rows.account!,
          pickleKey,
        );
        final List<int> plain;
        try {
          plain = account.createInbound(identityKey, cipher).plaintext;
        } on KeyEngineException {
          onFail?.call('decrypt_fail');
          return null;
        }
        final text = decodeEnvelope(utf8.decode(plain), messageId);
        if (text == null) {
          onFail?.call('decrypt_fail');
        } else if (rows.sessions.isNotEmpty) {
          onStoredKey?.call();
        }
        return text?.text;
      }
    }
  } catch (e) {
    onFail?.call('other:${e.runtimeType}');
    return null;
  }
}

/// Reads peek rows and decrypts a message using them without persisting the result.
/// When [budgetLeftMs] is given (Android: the push time left, read at write time) and the text was opened by an already stored session or peer key (never by the push's own key), the text is also saved into push_inbox of the store; [onInbox] gets the fixed result code of that write (see writePushInbox).
/// The saved sender is the chat's peer from the store, never the push's sender.
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
  void Function(String name)? onPeerName,
  String? senderKey,
  String? senderId,
  int Function()? budgetLeftMs,
  void Function(String code)? onInbox,
}) async {
  final rows = readPeekRows(
    path: storePath,
    keyHex: storeKeyHex,
    conversationId: conversationId,
    messageId: messageId,
    senderKey: senderKey,
    senderId: senderId,
  );
  if (rows == null) {
    onFail?.call('rows_null');
    return null;
  }
  if (rows.ownerId != ownerId) {
    onFail?.call('owner_mismatch');
    return null;
  }
  // The name shown for this chat comes from the phone's own copy, not from the push.
  final name = rows.peerName;
  if (name != null) onPeerName?.call(name);
  // A stored text is the peer's preview only when the peer sent it; otherwise fall through to the decrypt path.
  if (rows.storedBody != null &&
      !isLockedPlaceholder(rows.storedBody!) &&
      rows.peerUserId != null &&
      rows.storedSenderId == rows.peerUserId) {
    return rows.storedBody;
  }
  var storedKey = false;
  final text = await peekDecrypt(
    rows: rows,
    pickleKey: pickleKey,
    messageId: messageId,
    ciphertext: ciphertext,
    olmType: olmType,
    onFail: onFail,
    senderKey: senderKey,
    senderId: senderId,
    onStoredKey: () => storedKey = true,
  );
  final peer = rows.peerUserId;
  if (text != null && storedKey && budgetLeftMs != null && peer != null) {
    onInbox?.call(
      writePushInbox(
        path: storePath,
        keyHex: storeKeyHex,
        conversationId: conversationId,
        messageId: messageId,
        peerUserId: peer,
        body: text,
        // Same hash as the app's own opener (message_opener.dart _openOne).
        sealed: sha256.convert(utf8.encode(ciphertext)).toString(),
        receivedAtMicros: DateTime.now().microsecondsSinceEpoch,
        budgetMs: budgetLeftMs(),
      ),
    );
  }
  return text;
}

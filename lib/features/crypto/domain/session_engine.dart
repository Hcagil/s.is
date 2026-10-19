import '../../../core/failure.dart';
import 'key_directory.dart';

/// Plaintext that is written to the stored message row [messageId] (body and search copy) in the same transaction as the session. If no such row is stored, nothing is written for it.
final class PlaintextSave {
  const PlaintextSave(this.messageId, this.plaintext);

  final String messageId;
  final String plaintext;
}

/// A locked message: [ciphertext] is base64 of the Olm message bytes, [olmType] 0 pre-key or 1 normal, [sessionId] the session that locked it.
final class LockedText {
  const LockedText({
    required this.ciphertext,
    required this.olmType,
    required this.sessionId,
  });

  final String ciphertext;
  final int olmType;
  final String sessionId;
}

abstract interface class SessionEngine {
  /// True when at least one session with [peerUserId] is stored.
  Future<bool> hasSession(String peerUserId);

  /// Opens and stores an outbound session from the contact's claimed keys. Ok(sessionId). Err(DeviceKeysFailure) when the keys do not verify or do not fit; Err(SessionStoreFailure) when nothing could be saved (no account, store error).
  Future<Result<String>> createOutbound(String peerUserId, ClaimedKeys keys);

  /// Locks [plaintext] (UTF-8) on the newest-used session with [peerUserId]. Err(SessionPendingFailure) when there is no session. Session pickle (new lastUsedAt) and [save] are written in ONE transaction before this returns.
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    PlaintextSave? save,
  });

  /// Makes an inbound session from a pre-key message ([olmType] must be 0) and returns its plaintext. Session, consumed-one-time-key account pickle and [save] are written in ONE transaction. Err(UnreadableMessageFailure) for a wrong type, bad base64, a message that does not open or non-UTF-8 plaintext; nothing is written then. A session with the message's id already stored is reused instead of replaced.
  Future<Result<String>> createInbound({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  });

  /// Opens a message from [peerUserId]. Pre-key (0): the stored session with the message's session id, else createInbound. Normal (1): the peer's sessions newest first. Err(SessionPendingFailure) when no session exists yet (retry when one appears); Err(UnreadableMessageFailure) when sessions exist and none opens it (MAC or authentication failure, final). Plaintext, session pickle (and account pickle when a one-time key was consumed) are written in ONE transaction; a failure writes nothing.
  Future<Result<String>> decrypt({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  });
}

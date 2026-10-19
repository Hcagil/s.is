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

/// Where [SessionEngine.encrypt] stores the ciphertext: the send_queue row (userId, queueId), written in the same transaction as the session pickle. If no such row exists nothing is written for it.
final class QueueTarget {
  const QueueTarget(this.userId, this.queueId);

  final String userId;
  final String queueId;
}

abstract interface class SessionEngine {
  /// True when at least one session with [peerUserId] is stored.
  Future<bool> hasSession(String peerUserId);

  /// Opens and stores an outbound session from the contact's claimed keys. Ok(sessionId). Err(DeviceKeysFailure) when the keys do not verify or do not fit; Err(SessionStoreFailure) when nothing could be saved (no account, store error). Sessions of that peer made for another identity key are deleted in the same transaction.
  Future<Result<String>> createOutbound(String peerUserId, ClaimedKeys keys);

  /// Locks [plaintext] (UTF-8) on the newest-used session with [peerUserId] whose stored identity key equals [peerIdentityKey] (the peer's current directory key checked with verifyDevice). Sessions made for another key are not used. Err(SessionPendingFailure) when no session matches: the caller runs createOutbound. Session pickle (new lastUsedAt), [save] and, when [queue] is given, the ciphertext and olmType on the send_queue row are written in ONE transaction before this returns.
  Future<Result<LockedText>> encrypt(
    String peerUserId,
    String plaintext, {
    required String peerIdentityKey,
    PlaintextSave? save,
    QueueTarget? queue,
  });

  /// Makes an inbound session from a pre-key message ([olmType] must be 0) and returns its plaintext. Session, consumed-one-time-key account pickle and [save] are written in ONE transaction. Err(UnreadableMessageFailure) for a wrong type, bad base64, a message that does not open or non-UTF-8 plaintext; nothing is written then. A session with the message's id already stored is reused instead of replaced. [peerUserId] must be the server-enforced sender_id of the message. [peerIdentityKey] must be the directory key checked with verifyDevice, never a key read from the message. Sessions of that peer made for another identity key are deleted in the same transaction.
  Future<Result<String>> createInbound({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  });

  /// Opens a message from [peerUserId]. Pre-key (0): the stored session with the message's session id, else createInbound. Normal (1): the peer's sessions newest first. Err(SessionPendingFailure) when no session exists yet (retry when one appears); Err(UnreadableMessageFailure) when sessions exist and none opens it (MAC or authentication failure, final). Plaintext, session pickle (and account pickle when a one-time key was consumed) are written in ONE transaction; a failure writes nothing. [peerUserId] must be the server-enforced sender_id of the message. [peerIdentityKey] must be the directory key checked with verifyDevice, never a key read from the message. Only sessions stored for that key are used; none gives Err(SessionPendingFailure) for type 1.
  Future<Result<String>> decrypt({
    required String peerUserId,
    required String peerIdentityKey,
    required String ciphertext,
    required int olmType,
    PlaintextSave? save,
  });
}

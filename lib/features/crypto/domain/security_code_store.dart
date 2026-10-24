/// The two keys of a contact's phone that were compared by a person and marked "matches" on THIS phone.
final class VerifiedKeys {
  const VerifiedKeys({required this.curve25519, required this.ed25519});
  final String curve25519;
  final String ed25519;

  @override
  bool operator ==(Object other) =>
      other is VerifiedKeys &&
      other.curve25519 == curve25519 &&
      other.ed25519 == ed25519;

  @override
  int get hashCode => Object.hash(curve25519, ed25519);
}

/// The last time a contact's key changed on this phone (a new session for a new identity key).
final class KeyChange {
  const KeyChange({required this.at, required this.wasVerified});

  /// When this phone saw the change.
  final DateTime at;

  /// The contact was marked verified before the change.
  final bool wasVerified;
}

/// This phone's own two public keys.
final class OwnKeys {
  const OwnKeys({required this.curve25519, required this.ed25519});
  final String curve25519;
  final String ed25519;
}

/// What this phone remembers for security codes. Everything stays on the phone.
abstract interface class SecurityCodeStore {
  /// This phone's own identity (Curve25519) and signing (Ed25519) keys; null when no account is stored.
  Future<OwnKeys?> ownKeys();

  /// The identity key of the newest-used stored session with [peerUserId]; null when there is none. This is the only key the peer half of a code may come from.
  Future<String?> sessionPeerKey(String peerUserId);

  /// The keys marked as verified for [peerUserId], or null.
  Future<VerifiedKeys?> verified(String peerUserId);

  /// Remembers [keys] as verified for [peerUserId] (replaces an older mark).
  Future<void> markVerified(String peerUserId, VerifiedKeys keys);

  /// Removes the verified mark of [peerUserId].
  Future<void> clearVerified(String peerUserId);

  /// The last key change seen for [peerUserId], or null.
  Future<KeyChange?> keyChange(String peerUserId);
}

/// Remembers per chat that it has held a locked (encrypted) text.
abstract interface class CipherChatMemory {
  /// When the first locked text of [conversationId] was created (earliest one remembered); null when the chat never held one.
  Future<DateTime?> heldSince(String conversationId);

  /// Remembers a locked text created at [at] in [conversationId]; keeps the earlier time if one is already stored.
  Future<void> markHeld(String conversationId, DateTime at);
}

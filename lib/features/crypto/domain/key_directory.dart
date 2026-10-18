import '../../../core/failure.dart';

/// The text a phone signs to bind its two public keys to its member id. Both phones must build it the same way.
String deviceStatement(String userId, String identityKey, String signingKey) =>
    'sis-olm-v1|$userId|$identityKey|$signingKey';

/// One phone's published keys as the server hands them to a chat partner.
final class ClaimedKeys {
  const ClaimedKeys({
    required this.identityKey,
    required this.signingKey,
    required this.deviceSignature,
    required this.oneTimeKey,
    required this.isFallback,
  });
  final String identityKey;
  final String signingKey;
  final String deviceSignature;

  /// A one-time key, or the fallback key when [isFallback].
  final String oneTimeKey;
  final bool isFallback;
}

/// What the server holds for the signed-in member's own phone.
final class PublishedStatus {
  const PublishedStatus({
    required this.identityKey,
    required this.signingKey,
    required this.oneTimeKeys,
    required this.hasFallback,
    required this.fallbackUsed,
    required this.sameSession,
  });
  final String identityKey;
  final String signingKey;

  /// Free (unclaimed) one-time keys on the server.
  final int oneTimeKeys;
  final bool hasFallback;
  final bool fallbackUsed;

  /// The server row is bound to this very session (false after a sign-out and sign-in, or on a new phone).
  final bool sameSession;
}

/// The key directory on the server (RPCs publish_olm_keys, claim_olm_keys, olm_key_status).
abstract interface class KeyDirectory {
  /// Publishes (or re-publishes, idempotent) this phone's keys; an empty [oneTimeKeys] just rebinds the live session. Ok = free one-time keys now on the server. Err(DeniedFailure) when the session is not the active one; Err(SearchLimitFailure) on the server rate limit (RLMT1).
  Future<Result<int>> publish({
    required String identityKey,
    required String signingKey,
    required String deviceSignature,
    required List<String> oneTimeKeys,
    String? fallbackKey,
  });

  /// Claims one key of [userId]'s phone. Ok(null) when that member has no live published phone. Err(DeniedFailure) when not allowed to chat with them (42501).
  Future<Result<ClaimedKeys?>> claim(String userId);

  /// This member's own row; Ok(null) when nothing is published yet.
  Future<Result<PublishedStatus?>> status();
}

/// Where the encrypted account pickle lives on this phone (inside the encrypted on-phone store).
abstract interface class OlmPickleStore {
  /// The saved pickle, or null when none (or unreadable).
  Future<String?> load();

  /// True when the pickle was saved.
  Future<bool> save(String pickle);
}

/// The 32-byte key that encrypts the pickle, kept in the platform's secure storage.
abstract interface class PickleKeyStore {
  Future<List<int>> loadOrCreate();
  Future<void> delete();
}

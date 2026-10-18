import 'key_directory.dart';

/// Thrown when the engine cannot do what was asked (bad pickle, bad key). Carries no text on purpose: nothing from keys or pickles may reach logs or screens.
final class KeyEngineException implements Exception {
  const KeyEngineException();
}

/// One Olm account (this phone's identity and keys).
abstract interface class KeyAccount {
  String get identityKey;
  String get signingKey;
  int get maxOneTimeKeys;
  int get storedOneTimeKeyCount;

  /// Makes [count] new one-time keys (unpublished until markPublished).
  void generateOneTimeKeys(int count);
  void generateFallbackKey();
  List<String> get unpublishedOneTimeKeys;
  String? get unpublishedFallbackKey;
  void markPublished();

  /// Signs [message] with the account's signing key (base64).
  String sign(String message);

  /// The encrypted pickle (throws KeyEngineException on a bad key).
  String pickle(List<int> key);
}

/// The Olm engine (vodozemac). Everything async because the native library loads on first use.
abstract interface class KeyEngine {
  Future<KeyAccount> create();

  /// Throws KeyEngineException when the pickle cannot be read with [key].
  Future<KeyAccount> restore(String pickle, List<int> key);

  /// True only when [keys].deviceSignature is a valid signature of deviceStatement(userId, identityKey, signingKey) by [keys].signingKey.
  Future<bool> verifyDevice(String userId, ClaimedKeys keys);
}

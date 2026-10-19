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

/// One Olm ciphertext: [type] 0 is a pre-key message, 1 a normal message.
final class OlmCipher {
  const OlmCipher(this.type, this.body);

  final int type;
  final List<int> body;
}

/// One Olm session with one contact. Methods throw [KeyEngineException] on any engine failure (bad MAC, bad key, bad pickle).
abstract interface class KeySession {
  String get sessionId;

  OlmCipher encrypt(List<int> plaintext);

  List<int> decrypt(OlmCipher message);

  /// The encrypted pickle.
  String pickle(List<int> key);
}

/// A session made from a contact's pre-key message, with the plaintext of that message.
final class InboundSession {
  const InboundSession(this.session, this.plaintext);

  final KeySession session;
  final List<int> plaintext;
}

/// An account that can also open sessions. Its inbound call removes the used one-time key, so the account must be pickled and saved after it.
abstract interface class SessionAccount implements KeyAccount {
  /// Throws KeyEngineException on a bad key.
  KeySession createOutbound(String theirIdentityKey, String theirOneTimeKey);

  /// Throws KeyEngineException when [message] is not a pre-key message or does not fit a key of this account.
  InboundSession createInbound(String theirIdentityKey, OlmCipher message);
}

/// The session side of the Olm engine.
abstract interface class SessionKeyEngine {
  /// Like [KeyEngine.restore] but the account can open sessions. Throws KeyEngineException.
  Future<SessionAccount> restoreSessionAccount(String pickle, List<int> key);

  /// Throws KeyEngineException when the pickle cannot be read with [key].
  Future<KeySession> restoreSession(String pickle, List<int> key);

  /// The id of the session a pre-key [message] belongs to. Throws KeyEngineException when it is not a pre-key message.
  Future<String> preKeySessionId(OlmCipher message);
}

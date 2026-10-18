import '../../../data/crypto/rust/api/olm.dart' as olm;
import '../../../data/crypto/rust/frb_generated.dart';
import '../domain/key_directory.dart';
import '../domain/key_engine.dart';

final class OlmKeyEngine implements KeyEngine {
  static Future<void>? _ready;

  // A failed init is forgotten so the next call retries; success stays memoised.
  static Future<void> _init() async {
    try {
      await (_ready ??= RustLib.init());
    } catch (_) {
      _ready = null;
      throw const KeyEngineException();
    }
  }

  @override
  Future<KeyAccount> create() async {
    await _init();
    return _Account(olm.OlmAccount());
  }

  @override
  Future<KeyAccount> restore(String pickle, List<int> key) async {
    await _init();
    try {
      return _Account(olm.OlmAccount.fromPickle(pickle: pickle, key: key));
    } catch (_) {
      throw const KeyEngineException();
    }
  }

  @override
  Future<bool> verifyDevice(String userId, ClaimedKeys keys) async {
    await _init();
    try {
      olm.olmVerify(
        signingKey: keys.signingKey,
        message: deviceStatement(userId, keys.identityKey, keys.signingKey),
        signature: keys.deviceSignature,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

final class _Account implements KeyAccount {
  final olm.OlmAccount _a;

  _Account(this._a);

  @override
  String get identityKey => _a.identityKey();

  @override
  String get signingKey => _a.ed25519Key();

  @override
  int get maxOneTimeKeys => _a.maxOneTimeKeys();

  @override
  int get storedOneTimeKeyCount => _a.storedOneTimeKeyCount();

  @override
  void generateOneTimeKeys(int count) {
    _a.generateOneTimeKeys(count: count);
  }

  @override
  void generateFallbackKey() {
    _a.generateFallbackKey();
  }

  @override
  List<String> get unpublishedOneTimeKeys => _a.unpublishedOneTimeKeys();

  @override
  String? get unpublishedFallbackKey => _a.unpublishedFallbackKey();

  @override
  void markPublished() {
    _a.markKeysAsPublished();
  }

  @override
  String sign(String message) {
    return _a.sign(message: message);
  }

  @override
  String pickle(List<int> key) {
    try {
      return _a.pickle(key: key);
    } catch (_) {
      throw const KeyEngineException();
    }
  }
}

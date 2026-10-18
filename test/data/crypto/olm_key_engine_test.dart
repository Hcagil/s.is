// OlmKeyEngine over the real compiled Rust library. No RustLib.init() here:
// the engine loads the library itself, as in the app.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

void main() {
  test('OlmKeyEngine device verification', () async {
    final engine = OlmKeyEngine();
    final account = await engine.create();
    final statement = deviceStatement(
      'u1',
      account.identityKey,
      account.signingKey,
    );
    final keys = ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: account.sign(statement),
      oneTimeKey: 'k',
      isFallback: false,
    );
    expect(await engine.verifyDevice('u1', keys), isTrue);
    expect(await engine.verifyDevice('u2', keys), isFalse);
    final account2 = await engine.create();
    final keys2 = ClaimedKeys(
      identityKey: account2.identityKey,
      signingKey: account2.signingKey,
      deviceSignature: account.sign(statement),
      oneTimeKey: 'k',
      isFallback: false,
    );
    expect(await engine.verifyDevice('u1', keys2), isFalse);
    // Only the curve25519 identity swapped (the attack the self-signature binds).
    final swapped = ClaimedKeys(
      identityKey: account2.identityKey,
      signingKey: account.signingKey,
      deviceSignature: account.sign(statement),
      oneTimeKey: 'k',
      isFallback: false,
    );
    expect(await engine.verifyDevice('u1', swapped), isFalse);
    final badSignature = account.sign('bad');
    final badKeys = ClaimedKeys(
      identityKey: account.identityKey,
      signingKey: account.signingKey,
      deviceSignature: badSignature,
      oneTimeKey: 'k',
      isFallback: false,
    );
    expect(await engine.verifyDevice('u1', badKeys), isFalse);
  });

  test('OlmKeyEngine restore with wrong key throws', () async {
    final engine = OlmKeyEngine();
    final account = await engine.create();
    final key32 = List.generate(32, (i) => i);
    final pickle = account.pickle(key32);
    expect(
      () => engine.restore(pickle, List.generate(32, (i) => i + 1)),
      throwsA(isA<KeyEngineException>()),
    );
    expect(
      () => account.pickle(List.generate(31, (i) => i)),
      throwsA(isA<KeyEngineException>()),
    );
  });
}

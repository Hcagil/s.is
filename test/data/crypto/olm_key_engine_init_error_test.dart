// Drafted by test_writer from the contract; reviewed by qa-lead.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/crypto/rust/frb_generated.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

void main() {
  test('OlmKeyEngine init failure is retried on subsequent create()', () async {
    final engine = OlmKeyEngine();

    // First init attempt fails because RustLib is already initialised.
    await RustLib.init();
    KeyEngineException? firstException;
    try {
      await engine.create();
      fail('create() should have thrown a KeyEngineException');
    } on KeyEngineException catch (e) {
      firstException = e;
    }
    expect(firstException, isNotNull);
    expect(firstException.cause, isNotNull);
    expect(firstException.causeStackTrace, isNotNull);
    expect(
      firstException.toString(),
      equals('KeyEngineException: ${firstException.cause}'),
    );

    // Second call on the same engine instance retries init and still fails.
    KeyEngineException? secondException;
    try {
      await engine.create();
      fail('create() should have thrown a KeyEngineException on retry');
    } on KeyEngineException catch (e) {
      secondException = e;
    }
    expect(secondException, isNotNull);
    expect(secondException.cause, isNotNull);
    expect(secondException.causeStackTrace, isNotNull);

    // Clean up RustLib and try again; this should succeed.
    RustLib.dispose();
    final account = await engine.create();
    expect(account.identityKey, hasLength(43));
  });
}

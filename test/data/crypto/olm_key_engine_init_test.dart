// OlmKeyEngine's lazy library load: a failed RustLib.init() must not be
// remembered; the next create() tries again. Init is made to fail through the
// public FRB API only: a library already initialised by someone else refuses
// a second init, and RustLib.dispose() frees it again. Own file: own isolate.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/crypto/rust/frb_generated.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

void main() {
  test('a failed init is retried by the next create()', () async {
    await RustLib.init();
    await expectLater(
      OlmKeyEngine().create(),
      throwsA(isA<KeyEngineException>()),
      reason: 'the engine\'s own init fails while the library is held',
    );

    RustLib.dispose();
    final account = await OlmKeyEngine().create();
    expect(account.identityKey, hasLength(43));
  });
}

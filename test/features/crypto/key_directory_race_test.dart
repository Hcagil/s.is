// The seam between KeyDirectoryController and DriftSessionEngine: both write
// the one Olm account in the same REAL encrypted store, through the REAL
// OlmKeyEngine (vodozemac). Only the network directory is faked, so its
// publish can pause while an inbound pre-key message consumes a one-time key.
// Wired with the same four providers main.dart overrides.
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import '../../support/key_directory_fakes.dart';
import '../chat/data/store/store_harness.dart';
import 'data/drift_session_engine_test.dart' show Phone, ok, err;

/// Real time passes (native calls and SQLite are real I/O).
Future<void> until(bool Function() done, String what) async {
  for (var i = 0; i < 1000; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for $what');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('a one-time key consumed by an inbound session during the publish '
      'stays consumed after markPublished', () async {
    final h = await StoreHarness.create();
    final store = h.open(owner: 'bob', key: await h.newKey());
    addTearDown(store.close);
    final olm = OlmKeyEngine();
    final dir = FakeKeyDirectory([]);
    final paused = Completer<Result<int>>();
    dir.publishAnswers.add(paused.future);

    final c = ProviderContainer(
      overrides: [
        sessionControllerProvider.overrideWith(
          () => DrivenSession(
            const Allowed(Member(userId: 'bob', displayName: 'Bob')),
          ),
        ),
        keyDirectoryProvider.overrideWithValue(dir),
        keyEngineProvider.overrideWithValue(olm),
        olmPickleStoreProvider.overrideWithValue(DriftOlmPickleStore(store)),
        pickleKeyStoreProvider.overrideWithValue(FakePickleKeys()),
      ],
    );
    addTearDown(c.dispose);
    c.listen(keyDirectoryControllerProvider, (_, _) {});

    await until(() => dir.publishes.isNotEmpty, 'the first publish');
    final pub = dir.publishes.single;
    expect(pub.oneTimeKeys, isNotEmpty);
    ClaimedKeys claimed(String otk) => ClaimedKeys(
      identityKey: pub.identityKey,
      signingKey: pub.signingKey,
      deviceSignature: pub.deviceSignature,
      oneTimeKey: otk,
      isFallback: false,
    );

    // Bob's session engine over the same store and pickle key.
    final bob = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: FakePickleKeys(),
      now: DateTime.now,
    );
    Future<Result<String>> bobOpens(Phone from, String ciphertext) =>
        bob.createInbound(
          peerUserId: from.userId,
          peerIdentityKey: from.identityKey,
          ciphertext: ciphertext,
          olmType: 0,
        );

    // While the publish is on the network, Alice claims key 0 and writes.
    final alice = await Phone.make('alice');
    ok(await alice.engine.createOutbound('bob', claimed(pub.oneTimeKeys[0])));
    final m = ok(
      await alice.engine.encrypt(
        'bob',
        'ilk',
        peerIdentityKey: pub.identityKey,
      ),
    );
    expect(ok(await bobOpens(alice, m.ciphertext)), 'ilk');
    expect(
      c.read(keyDirectoryControllerProvider),
      isNot(isA<KeysReady>()),
      reason: 'the publish is still paused',
    );

    paused.complete(const Ok(50));
    await until(
      () => c.read(keyDirectoryControllerProvider) is KeysReady,
      'KeysReady',
    );

    // A second pre-key aimed at the consumed key must not open.
    final carol = await Phone.make('carol');
    ok(await carol.engine.createOutbound('bob', claimed(pub.oneTimeKeys[0])));
    final again = ok(
      await carol.engine.encrypt(
        'bob',
        'ikinci',
        peerIdentityKey: pub.identityKey,
      ),
    );
    expect(
      err(await bobOpens(carol, again.ciphertext)),
      isA<UnreadableMessageFailure>(),
      reason: 'the consumed one-time key came back with markPublished',
    );

    // Control: a key of the same publish that nobody used still opens.
    final dave = await Phone.make('dave');
    ok(await dave.engine.createOutbound('bob', claimed(pub.oneTimeKeys[1])));
    final fresh = ok(
      await dave.engine.encrypt(
        'bob',
        'üçüncü',
        peerIdentityKey: pub.identityKey,
      ),
    );
    expect(ok(await bobOpens(dave, fresh.ciphertext)), 'üçüncü');
    expect(
      await bob.hasSession('alice'),
      isTrue,
      reason: 'the session made during the publish survived',
    );
  });
}

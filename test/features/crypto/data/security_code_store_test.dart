// The security code memory on the phone, end to end over REAL parts: two (or
// three) phones, each with its own encrypted store file, a real Olm account
// (vodozemac through OlmKeyEngine) and a real DriftSessionEngine; the code
// store is the real DriftSecurityCodeStore over the same file. Written from
// the t_a9ef0f411f contract and audit findings L4 / security must-haves 4-6,
// never from the implementation. Needs the Rust library
// (cargo build --release --manifest-path rust/Cargo.toml), as CI builds it.
import 'dart:convert';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/security_code_controller.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/crypto/data/drift_security_code_store.dart';
import 'package:sis/features/crypto/data/drift_session_engine.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';
import 'package:sis/features/crypto/domain/security_code_store.dart';
import 'package:sis/features/crypto/domain/session_engine.dart';

import '../../../support/key_directory_fakes.dart';
import '../../chat/data/store/store_harness.dart';

const aliceId = 'aaaaaaaa-0000-4000-8000-000000000001';
const bobId = 'bbbbbbbb-0000-4000-8000-000000000002';
const carolId = 'cccccccc-0000-4000-8000-000000000003';

final t0 = DateTime.utc(2026, 3, 1);

final class _FixedPickleKey implements PickleKeyStore {
  _FixedPickleKey(this.key);
  final List<int> key;
  @override
  Future<List<int>> loadOrCreate() async => key;
  @override
  Future<void> delete() async {}
}

/// One phone: store file, Olm account, session engine and code store.
final class Phone {
  Phone._(this.userId, this.store, this.engine, this.codes, this.account);

  final String userId;
  final DriftMessageStore store;
  final DriftSessionEngine engine;
  final DriftSecurityCodeStore codes;
  final KeyAccount account;
  late final List<String> _otks;
  var _next = 0;

  String get identityKey => account.identityKey;
  String get signingKey => account.signingKey;

  static Future<Phone> make(String userId) async {
    final h = await StoreHarness.create();
    final store = h.open(owner: userId, key: await h.newKey());
    addTearDown(store.close);
    final olm = OlmKeyEngine();
    final pk = List<int>.generate(
      32,
      (i) => (i * 5 + userId.codeUnitAt(0)) % 256,
    );
    final account = await olm.create();
    account.generateOneTimeKeys(6);
    final otks = account.unpublishedOneTimeKeys;
    account.markPublished();
    expect(await DriftOlmPickleStore(store).save(account.pickle(pk)), isTrue);
    var clock = 0;
    final engine = DriftSessionEngine(
      store: store,
      keys: olm,
      sessions: olm,
      pickleKey: _FixedPickleKey(pk),
      now: () => t0.add(Duration(seconds: ++clock)),
    );
    final codes = DriftSecurityCodeStore(
      store: store,
      sessions: olm,
      pickleKey: _FixedPickleKey(pk),
    );
    return Phone._(userId, store, engine, codes, account).._otks = otks;
  }

  /// The directory entry this phone published (self-signed), with a fresh
  /// one-time key.
  ClaimedKeys keys() => ClaimedKeys(
    identityKey: identityKey,
    signingKey: signingKey,
    deviceSignature: account.sign(
      deviceStatement(userId, identityKey, signingKey),
    ),
    oneTimeKey: _otks[_next++],
    isFallback: false,
  );

  /// Opens a session to [to] and locks [text] (a pre-key message, type 0).
  Future<LockedText> sendFirst(Phone to, [String text = 'merhaba']) async {
    ok(await engine.createOutbound(to.userId, to.keys()));
    return ok(
      await engine.encrypt(to.userId, text, peerIdentityKey: to.identityKey),
    );
  }

  /// Opens [m] as sent by [from] with the directory key [identityKey].
  Future<Result<String>> open(
    LockedText m, {
    required String from,
    required String identityKey,
  }) => engine.decrypt(
    peerUserId: from,
    peerIdentityKey: identityKey,
    ciphertext: m.ciphertext,
    olmType: m.olmType,
  );

  Future<List<(String, String)>> sessionRows() => store.run(
    const [],
    (db) async => [
      for (final r
          in await db
              .customSelect(
                'SELECT peer_user_id, peer_identity_key FROM olm_sessions '
                'ORDER BY peer_user_id',
              )
              .get())
        (r.read<String>('peer_user_id'), r.read<String>('peer_identity_key')),
    ],
  );

  Future<String?> meta(String key) => store.run<String?>(
    null,
    (db) async =>
        (await db
                .customSelect(
                  'SELECT value FROM meta WHERE key = ?',
                  variables: [Variable.withString(key)],
                )
                .getSingleOrNull())
            ?.read<String>('value'),
  );
}

T ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok, got $r');
  return (r as Ok<T>).value;
}

Failure err(Result<Object?> r) {
  expect(r, isA<Err<Object?>>(), reason: 'expected Err, got $r');
  return (r as Err<Object?>).failure;
}

VerifiedKeys keysOf(Phone p) =>
    VerifiedKeys(curve25519: p.identityKey, ed25519: p.signingKey);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Phone alice;
  late Phone bob;

  setUp(() async {
    alice = await Phone.make(aliceId);
    bob = await Phone.make(bobId);
  });

  /// Bob opens Alice's first message: one session on each phone.
  Future<void> established() async {
    final m = await alice.sendFirst(bob);
    ok(await bob.open(m, from: aliceId, identityKey: alice.identityKey));
  }

  group('DriftSecurityCodeStore', () {
    test('ownKeys are this phone\'s account keys', () async {
      final own = await bob.codes.ownKeys();
      expect(own?.curve25519, bob.identityKey);
      expect(own?.ed25519, bob.signingKey);
    });

    test('sessionPeerKey: null with no session, then the key of the session '
        'in use', () async {
      expect(await bob.codes.sessionPeerKey(aliceId), isNull);
      await established();
      expect(await bob.codes.sessionPeerKey(aliceId), alice.identityKey);
      expect(await alice.codes.sessionPeerKey(bobId), bob.identityKey);
      expect(await bob.codes.sessionPeerKey(carolId), isNull);
    });

    test('verified mark: stored in this phone\'s meta table under '
        'verified:<peer>, read back, cleared', () async {
      expect(await bob.codes.verified(aliceId), isNull);
      await bob.codes.markVerified(aliceId, keysOf(alice));
      expect(await bob.codes.verified(aliceId), keysOf(alice));
      expect(await bob.meta(verifiedMetaKey(aliceId)), isNotNull);
      expect(await bob.codes.verified(carolId), isNull);
      await bob.codes.clearVerified(aliceId);
      expect(await bob.codes.verified(aliceId), isNull);
      expect(await bob.meta(verifiedMetaKey(aliceId)), isNull);
    });

    test('heldSince keeps the earliest locked text per chat', () async {
      expect(await bob.codes.heldSince('c1'), isNull);
      await bob.codes.markHeld('c1', t0.add(const Duration(minutes: 5)));
      await bob.codes.markHeld('c1', t0.add(const Duration(minutes: 9)));
      expect(
        (await bob.codes.heldSince('c1'))?.toUtc(),
        t0.add(const Duration(minutes: 5)),
      );
      await bob.codes.markHeld('c1', t0.add(const Duration(minutes: 1)));
      expect(
        (await bob.codes.heldSince('c1'))?.toUtc(),
        t0.add(const Duration(minutes: 1)),
      );
      expect(await bob.codes.heldSince('c2'), isNull);
    });
  });

  group('a key change on the phone (_retireOthers)', () {
    test('the first session is no key change', () async {
      await established();
      expect(await bob.codes.keyChange(aliceId), isNull);
      expect(await alice.codes.keyChange(bobId), isNull);
    });

    test(
      'another session on the SAME key keeps the mark and is no change',
      () async {
        await established();
        await bob.codes.markVerified(aliceId, keysOf(alice));
        final again = await alice.sendFirst(bob, 'ikinci');
        expect(
          ok(
            await bob.open(
              again,
              from: aliceId,
              identityKey: alice.identityKey,
            ),
          ),
          'ikinci',
        );
        expect(await bob.codes.keyChange(aliceId), isNull);
        expect(await bob.codes.verified(aliceId), keysOf(alice));
      },
    );

    test(
      'inbound: the peer reinstalled and a pre-key message on the new key '
      'opens: the mark is cleared and a change (was verified) is recorded',
      () async {
        await established();
        await bob.codes.markVerified(aliceId, keysOf(alice));
        final alice2 = await Phone.make(aliceId);
        final m = await alice2.sendFirst(bob, 'yeni');
        expect(
          ok(await bob.open(m, from: aliceId, identityKey: alice2.identityKey)),
          'yeni',
        );
        expect(await bob.codes.verified(aliceId), isNull);
        final change = await bob.codes.keyChange(aliceId);
        expect(change, isNotNull);
        expect(change!.wasVerified, isTrue);
        expect(change.at.toUtc().isAfter(t0), isTrue);
        expect(await bob.codes.sessionPeerKey(aliceId), alice2.identityKey);
      },
    );

    test('inbound, never verified: a change with wasVerified false', () async {
      await established();
      final alice2 = await Phone.make(aliceId);
      final m = await alice2.sendFirst(bob);
      ok(await bob.open(m, from: aliceId, identityKey: alice2.identityKey));
      final change = await bob.codes.keyChange(aliceId);
      expect(change?.wasVerified, isFalse);
    });

    test('outbound: a session to the peer\'s new key clears the mark and '
        'records the change', () async {
      await established();
      await alice.codes.markVerified(bobId, keysOf(bob));
      final bob2 = await Phone.make(bobId);
      ok(await alice.engine.createOutbound(bobId, bob2.keys()));
      expect(await alice.codes.verified(bobId), isNull);
      expect((await alice.codes.keyChange(bobId))?.wasVerified, isTrue);
    });

    test('a refused new session changes nothing', () async {
      await established();
      await bob.codes.markVerified(aliceId, keysOf(alice));
      final alice2 = await Phone.make(aliceId);
      final m = await alice2.sendFirst(bob);
      final bytes = base64Decode(m.ciphertext);
      bytes[bytes.length - 1] ^= 0x01; // tampered: the MAC fails
      final bad = LockedText(
        ciphertext: base64Encode(bytes),
        olmType: 0,
        sessionId: m.sessionId,
      );
      expect(
        await bob.open(bad, from: aliceId, identityKey: alice2.identityKey),
        isA<Err<String>>(),
      );
      expect(await bob.codes.verified(aliceId), keysOf(alice));
      expect(await bob.codes.keyChange(aliceId), isNull);
    });
  });

  group('L4: one identity key belongs to one member', () {
    late Phone carol;
    setUp(() async => carol = await Phone.make(carolId));

    test('outbound: a directory entry for carol carrying alice\'s identity '
        'key (signature valid, server-made) is DeviceKeysFailure', () async {
      await established(); // bob holds alice's key for alice
      final forged = ClaimedKeys(
        identityKey: alice.identityKey,
        signingKey: carol.signingKey,
        deviceSignature: carol.account.sign(
          deviceStatement(carolId, alice.identityKey, carol.signingKey),
        ),
        oneTimeKey: alice.keys().oneTimeKey,
        isFallback: false,
      );
      expect(
        err(await bob.engine.createOutbound(carolId, forged)),
        isA<DeviceKeysFailure>(),
      );
      expect((await bob.sessionRows()).where((r) => r.$1 == carolId), isEmpty);
    });

    test(
      'control: the same forged shape on a key nobody holds opens',
      () async {
        final forged = ClaimedKeys(
          identityKey: alice.identityKey,
          signingKey: carol.signingKey,
          deviceSignature: carol.account.sign(
            deviceStatement(carolId, alice.identityKey, carol.signingKey),
          ),
          oneTimeKey: alice.keys().oneTimeKey,
          isFallback: false,
        );
        ok(await bob.engine.createOutbound(carolId, forged));
      },
    );

    test(
      'inbound: alice\'s pre-key message relabelled as carol\'s (with '
      'alice\'s key as carol\'s directory key) is Unreadable, no session',
      () async {
        await established();
        final m = await alice.sendFirst(bob, 'gizli');
        final before = await bob.sessionRows();
        expect(
          err(await bob.open(m, from: carolId, identityKey: alice.identityKey)),
          isA<UnreadableMessageFailure>(),
        );
        expect(await bob.sessionRows(), before);
      },
    );

    test('vodozemac: a pre-key message whose identity key is not the '
        'directory key is refused (no stored session at all)', () async {
      final m = await alice.sendFirst(bob, 'gizli');
      expect(
        err(await bob.open(m, from: aliceId, identityKey: carol.identityKey)),
        isA<UnreadableMessageFailure>(),
      );
      expect(await bob.sessionRows(), isEmpty);
      // control: the same message with the right key opens
      expect(
        ok(await bob.open(m, from: aliceId, identityKey: alice.identityKey)),
        'gizli',
      );
    });
  });

  group('securityCodeProvider over the real store and signature check', () {
    ProviderContainer phoneApp(Phone me, Phone peer, {ClaimedKeys? dir}) {
      final log = <String>[];
      final c = ProviderContainer.test(
        overrides: [
          sessionControllerProvider.overrideWith(
            () => DrivenSession(
              Allowed(Member(userId: me.userId, displayName: 'x')),
            ),
          ),
          keyDirectoryProvider.overrideWithValue(
            FakeKeyDirectory(log)..identityAnswer = Ok(dir ?? peer.keys()),
          ),
          keyEngineProvider.overrideWithValue(OlmKeyEngine()),
          olmPickleStoreProvider.overrideWithValue(FakePickleStore(log)),
          pickleKeyStoreProvider.overrideWithValue(FakePickleKeys()),
          securityCodeStoreProvider.overrideWithValue(me.codes),
        ],
      );
      return c;
    }

    Future<SecurityCodeState> read(ProviderContainer c, String peer) async {
      await c.read(sessionControllerProvider.future);
      c.listen(currentUserIdProvider, (_, _) {});
      final sub = c.listen(securityCodeProvider(peer), (_, _) {});
      try {
        return await c.read(securityCodeProvider(peer).future);
      } finally {
        sub.close();
      }
    }

    test('both phones show the same 60 digits; verified on one phone only; '
        'a reinstall gives a new code that is not verified', () async {
      await established();
      final onBob = phoneApp(bob, alice);
      final onAlice = phoneApp(alice, bob);
      final b = await read(onBob, aliceId) as SecurityCodeReady;
      final a = await read(onAlice, bobId) as SecurityCodeReady;
      expect(b.digits, a.digits);
      expect(b.digits, matches(RegExp(r'^\d{60}$')));

      await onBob
          .read(securityCodeActionsProvider)
          .markVerified(aliceId, b.digits);
      expect(
        (await read(onBob, aliceId) as SecurityCodeReady).verified,
        isTrue,
      );
      expect(
        (await read(onAlice, bobId) as SecurityCodeReady).verified,
        isFalse,
      );

      final alice2 = await Phone.make(aliceId);
      final m = await alice2.sendFirst(bob);
      ok(await bob.open(m, from: aliceId, identityKey: alice2.identityKey));
      final after = await read(phoneApp(bob, alice2), aliceId);
      expect(after, isA<SecurityCodeReady>());
      after as SecurityCodeReady;
      expect(after.verified, isFalse);
      expect(after.digits, isNot(b.digits));
    });

    test('the directory still lists the old key while the session is on the '
        'new one => keyMismatch, no code', () async {
      await established();
      final alice2 = await Phone.make(aliceId);
      final m = await alice2.sendFirst(bob);
      ok(await bob.open(m, from: aliceId, identityKey: alice2.identityKey));
      final s = await read(phoneApp(bob, alice, dir: alice.keys()), aliceId);
      expect(s, isA<SecurityCodeUnavailable>());
      expect((s as SecurityCodeUnavailable).gap, SecurityCodeGap.keyMismatch);
    });

    test('a forged directory signature => no code', () async {
      await established();
      final k = alice.keys();
      final forged = ClaimedKeys(
        identityKey: k.identityKey,
        signingKey: bob.signingKey,
        deviceSignature: k.deviceSignature,
        oneTimeKey: '',
        isFallback: false,
      );
      final s = await read(phoneApp(bob, alice, dir: forged), aliceId);
      expect(s, isA<SecurityCodeUnavailable>());
    });
  });
}

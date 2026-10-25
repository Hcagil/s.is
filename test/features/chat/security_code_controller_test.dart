// securityCodeProvider and SecurityCodeActions, written from the contract
// (t_a9ef0f411f QA contract + security design check must-haves 1-4), never
// from the implementation. The REAL KeyDirectoryController sits between the
// provider and qa fakes of its server and signature check, wired through the
// providers main.dart overrides; the on-phone memory is the qa fake store.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/security_code_controller.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/security_code_store.dart';

import '../../support/key_directory_fakes.dart';
import '../../support/security_code_fakes.dart';

const me = '00000000-0000-4000-8000-00000000000a';
const peer = '00000000-0000-4000-8000-00000000000b';
const c11 = 'ERERERERERERERERERERERERERERERERERERERERERE=';
const e22 = 'IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=';
const c33 = 'MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=';
const e44 = 'REREREREREREREREREREREREREREREREREREREREREQ=';
const cSeq = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

/// The independently computed code of (me: c11/e22, peer: c33/e44).
const code = '641231018949145774472639426382083927211796311914359524400325';

/// The code once the peer's identity key is [cSeq].
const codeSeq = '641231018949145774472639426382837343994738377272804875749977';

ClaimedKeys dirKeys(String curve, String ed) => ClaimedKeys(
  identityKey: curve,
  signingKey: ed,
  deviceSignature: 'sig',
  oneTimeKey: '',
  isFallback: false,
);

class Rig {
  final KeyLog log = [];
  late final dir = FakeKeyDirectory(log)
    ..identityAnswer = Ok(dirKeys(c33, e44));
  late final engine = FakeEngine(log);
  final store = FakeSecurityCodeStore(
    own: const OwnKeys(curve25519: c11, ed25519: e22),
  )..sessions[peer] = c33;
  late final ProviderContainer c = ProviderContainer.test(
    overrides: [
      sessionControllerProvider.overrideWith(
        () => DrivenSession(
          const Allowed(Member(userId: me, displayName: 'Maya')),
        ),
      ),
      keyDirectoryProvider.overrideWithValue(dir),
      keyEngineProvider.overrideWithValue(engine),
      olmPickleStoreProvider.overrideWithValue(FakePickleStore(log)),
      pickleKeyStoreProvider.overrideWithValue(FakePickleKeys()),
      securityCodeStoreProvider.overrideWithValue(store),
    ],
  );

  Future<SecurityCodeState> state() async {
    await c.read(sessionControllerProvider.future);
    c.listen(currentUserIdProvider, (_, _) {});
    final sub = c.listen(securityCodeProvider(peer), (_, _) {});
    try {
      return await c.read(securityCodeProvider(peer).future);
    } finally {
      sub.close();
    }
  }

  SecurityCodeActions get actions => c.read(securityCodeActionsProvider);
}

SecurityCodeReady ready(SecurityCodeState s) {
  expect(s, isA<SecurityCodeReady>(), reason: 'expected a code, got $s');
  return s as SecurityCodeReady;
}

SecurityCodeGap gap(SecurityCodeState s) {
  expect(s, isA<SecurityCodeUnavailable>(), reason: 'expected no code, got $s');
  return (s as SecurityCodeUnavailable).gap;
}

void main() {
  group('securityCodeProvider', () {
    test('session key + signed directory Ed25519 for the same key: the '
        'code of both phones, not verified, with the keys shown', () async {
      final r = Rig();
      final s = ready(await r.state());
      expect(s.digits, code);
      expect(s.verified, isFalse);
      expect(s.peerKeys, const VerifiedKeys(curve25519: c33, ed25519: e44));
      expect(r.engine.verified.map((v) => v.$1), contains(peer));
    });

    test(
      'the peer half comes from the session row, never from the server: '
      'no session row => noSecureChat although the directory has keys',
      () async {
        final r = Rig()..store.sessions.clear();
        expect(gap(await r.state()), SecurityCodeGap.noSecureChat);
      },
    );

    test('directory key differs from the session key in use => keyMismatch, '
        'no code from the server key', () async {
      final r = Rig()..dir.identityAnswer = Ok(dirKeys(cSeq, e44));
      expect(gap(await r.state()), SecurityCodeGap.keyMismatch);
    });

    test('a directory signature that does not check => no code', () async {
      final r = Rig()..engine.verifyAnswer = false;
      expect(await r.state(), isA<SecurityCodeUnavailable>());
    });

    test(
      'no live phone in the directory (no Ed25519 key) => no code',
      () async {
        final r = Rig()..dir.identityAnswer = const Ok(null);
        expect(await r.state(), isA<SecurityCodeUnavailable>());
      },
    );

    test('directory offline => no code', () async {
      final r = Rig()
        ..dir.identityAnswer = const Err(
          NetworkFailure('No connection', retryable: true),
        );
      expect(await r.state(), isA<SecurityCodeUnavailable>());
    });

    test('no own account on the phone => no code', () async {
      final r = Rig()..store.own = null;
      expect(await r.state(), isA<SecurityCodeUnavailable>());
    });

    test('a malformed session key => no code', () async {
      final r = Rig()..store.sessions[peer] = 'not-a-key';
      r.dir.identityAnswer = Ok(dirKeys('not-a-key', e44));
      expect(await r.state(), isA<SecurityCodeUnavailable>());
    });

    test('verified is per (curve25519, ed25519): a mark for the same keys '
        'is verified, a mark for any other key is not', () async {
      final same = Rig()
        ..store.marks[peer] = const VerifiedKeys(curve25519: c33, ed25519: e44);
      expect(ready(await same.state()).verified, isTrue);

      final otherEd = Rig()
        ..store.marks[peer] = const VerifiedKeys(curve25519: c33, ed25519: e22);
      expect(ready(await otherEd.state()).verified, isFalse);

      final otherCurve = Rig()
        ..store.marks[peer] = const VerifiedKeys(
          curve25519: cSeq,
          ed25519: e44,
        );
      expect(ready(await otherCurve.state()).verified, isFalse);
    });

    test('a new session key (the peer\'s new phone) gives a new code and is '
        'not verified even if the old mark were still there', () async {
      final r = Rig()
        ..store.marks[peer] = const VerifiedKeys(curve25519: c33, ed25519: e44)
        ..store.sessions[peer] = cSeq
        ..dir.identityAnswer = Ok(dirKeys(cSeq, e44));
      final s = ready(await r.state());
      expect(s.digits, codeSeq);
      expect(s.verified, isFalse);
    });
  });

  group('SecurityCodeActions', () {
    test('markVerified with the code shown marks the current keys, on this '
        'phone only, and the state turns verified', () async {
      final r = Rig();
      expect(ready(await r.state()).verified, isFalse);
      final published = r.dir.publishes.length;
      await r.actions.markVerified(peer, code);
      expect(
        r.store.marks[peer],
        const VerifiedKeys(curve25519: c33, ed25519: e44),
      );
      expect(ready(await r.state()).verified, isTrue);
      expect(
        r.dir.publishes.length,
        published,
        reason: 'nothing goes to the server',
      );
    });

    test(
      'the keys changed after the code was shown: nothing is marked',
      () async {
        final r = Rig();
        expect(ready(await r.state()).digits, code);
        r.store.sessions[peer] = cSeq;
        r.dir.identityAnswer = Ok(dirKeys(cSeq, e44));
        await r.actions.markVerified(peer, code);
        expect(r.store.marks, isEmpty);
        expect(ready(await r.state()).verified, isFalse);
      },
    );

    test('a code that is not the current one marks nothing', () async {
      final r = Rig();
      expect(ready(await r.state()).digits, code);
      await r.actions.markVerified(peer, codeSeq);
      await r.actions.markVerified(peer, '');
      expect(r.store.marks, isEmpty);
    });

    test('no code (no session) marks nothing', () async {
      final r = Rig()..store.sessions.clear();
      await r.state();
      await r.actions.markVerified(peer, code);
      expect(r.store.marks, isEmpty);
    });

    test(
      'unmarkVerified clears the mark and the state turns unverified',
      () async {
        final r = Rig();
        expect(ready(await r.state()).digits, code); // the page showed it
        await r.actions.markVerified(peer, code);
        expect(ready(await r.state()).verified, isTrue);
        await r.actions.unmarkVerified(peer);
        expect(r.store.marks, isEmpty);
        expect(ready(await r.state()).verified, isFalse);
      },
    );
  });
}

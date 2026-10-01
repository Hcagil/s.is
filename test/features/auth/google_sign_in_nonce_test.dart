// Google sign-in's nonce, written from the contract (2026-09-29).
//
// Both sides are stand-ins that behave like the real thing, because the real
// thing cannot run here: an ID token only Google can sign, verified by a
// Supabase Auth configured with a Google provider. So:
//
// - the Google side is a GoogleSignInPlatform that behaves like the native
//   SDKs: whatever nonce `initialize` hands it is embedded in the ID token;
//   the iOS SDK embeds a nonce of its own when handed none, Android embeds
//   none. `initialize` takes a tick to finish, as a platform call does.
// - the Supabase side is the real SupabaseClient over an HTTP stand-in for
//   GoTrue's id_token grant that applies GoTrue's own nonce rules: exactly one
//   of {request nonce, token nonce} -> "should either both exist or not";
//   both, and lowercase-hex sha256(request nonce) != token nonce -> "Nonces
//   mismatch".
//
// NOT covered, and cannot be locally: a real Google-signed token accepted by a
// real Supabase Auth. That round trip is verified on a device.
import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/google_sign_in_stand_ins.dart';

/// Planted in every exception message, detail and response body a failure
/// path sees; the text the user is shown must never contain it.
const sentinel = 'SENTINEL-7f3a-raw-exception-text';

/// [r] is a ProviderFailure carrying exactly [message] (by default the
/// failed sentence), [userCanceled] as given, and no trace of [sentinel].
ProviderFailure expectFailed(
  Result<void> r, {
  required bool userCanceled,
  String message = signInFailedMessage,
}) {
  expect(r, isA<Err<void>>(), reason: '$r');
  final f = (r as Err<void>).failure;
  expect(f, isA<ProviderFailure>());
  expect(f.message, isNot(contains(sentinel)));
  expect(f.message, message);
  expect((f as ProviderFailure).userCanceled, userCanceled);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoTrueStandIn gotrue;
  final clients = <SupabaseClient>[];

  SupabaseAuthRepository repo({required bool useNonce}) {
    final c = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: gotrue.client,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    clients.add(c);
    return SupabaseAuthRepository(
      c,
      GoogleSignIn.instance,
      googleWebClientId: googleWebClient,
      useNonce: useNonce,
    );
  }

  late FakeGooglePlatform google;
  void platform({required bool ios}) =>
      GoogleSignInPlatform.instance = google = FakeGooglePlatform(ios: ios);

  setUp(() => gotrue = GoTrueStandIn());
  tearDown(() async {
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
  });

  test('the two sentences are the ones the contract names', () {
    expect(signInFailedMessage, 'Sign-in failed. Please try again.');
    expect(signInCanceledMessage, 'Sign-in was cancelled. Please try again.');
  });

  group('Android (useNonce false)', () {
    setUp(() => platform(ios: false));

    test(
      'no nonce anywhere: not to Google, not to Supabase; signs in',
      () async {
        final r = await repo(useNonce: false).signInWithGoogle();

        expect(r, isA<Ok<void>>(), reason: '$r');
        expect(google.inits, hasLength(1));
        expect(google.inits.single.nonce, isNull);
        expect(google.inits.single.serverClientId, googleWebClient);
        expect(gotrue.grants, hasLength(1));
        expect(gotrue.grants.single['nonce'], isNull);
        expect(gotrue.grants.single['provider'], 'google');
        expect(google.lastTokenNonce, isNull);
      },
    );
  });

  group('iOS (useNonce true)', () {
    setUp(() => platform(ios: true));

    test(
      'Google gets sha256hex(raw), Supabase gets raw; Supabase accepts',
      () async {
        final r = await repo(useNonce: true).signInWithGoogle();

        expect(r, isA<Ok<void>>(), reason: '$r');
        expect(google.inits, hasLength(1));
        final hashed = google.inits.single.nonce;
        expect(hashed, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(google.inits.single.serverClientId, googleWebClient);

        final raw = gotrue.grants.single['nonce'] as String?;
        expect(raw, isNotNull, reason: 'the raw nonce never reached Supabase');
        expect(
          raw,
          isNot(hashed),
          reason: 'Supabase got the hash, not the raw',
        );
        expect(sha256hex(raw!), hashed);
      },
    );

    test(
      'the raw nonce is 32 random bytes, base64url, 43 characters',
      () async {
        expect(await repo(useNonce: true).signInWithGoogle(), isA<Ok<void>>());
        final raw = gotrue.grants.single['nonce'] as String;

        expect(base64Url.decode(base64Url.normalize(raw)), hasLength(32));
        expect(raw, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      },
    );

    test('two sign-ins on one repository: initialize once, same nonce, both '
        'accepted', () async {
      final auth = repo(useNonce: true);
      expect(await auth.signInWithGoogle(), isA<Ok<void>>());
      final second = await auth.signInWithGoogle();

      expect(second, isA<Ok<void>>(), reason: '$second');
      expect(google.inits, hasLength(1), reason: 'initialize() ran twice');
      expect(gotrue.grants, hasLength(2));
      expect(gotrue.grants[0]['nonce'], gotrue.grants[1]['nonce']);
    });

    test('two repositories: different nonces', () async {
      expect(await repo(useNonce: true).signInWithGoogle(), isA<Ok<void>>());
      expect(await repo(useNonce: true).signInWithGoogle(), isA<Ok<void>>());

      expect(google.inits, hasLength(2));
      expect(google.inits[0].nonce, isNot(google.inits[1].nonce));
      expect(gotrue.grants[0]['nonce'], isNot(gotrue.grants[1]['nonce']));
    });

    test(
      'without a nonce, the iOS token carries the SDK\'s own and Supabase '
      'refuses: the defect this fixes, reproduced by the stand-ins',
      () async {
        final r = await repo(useNonce: false).signInWithGoogle();

        expect(r, isA<Err<void>>());
        final f = (r as Err<void>).failure;
        expect(f, isA<ProviderFailure>());
        expect(f.message, signInFailedMessage);
      },
    );
  });

  group('failure paths', () {
    for (final ios in [false, true]) {
      final name = ios ? 'iOS' : 'Android';
      group(name, () {
        setUp(() => platform(ios: ios));

        test('cancel -> ProviderFailure(userCanceled: true), Supabase not '
            'called', () async {
          google.error = const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
          );
          final r = await repo(useNonce: ios).signInWithGoogle();

          expect(r, isA<Err<void>>());
          final f = (r as Err<void>).failure;
          expect(f, isA<ProviderFailure>());
          expect((f as ProviderFailure).userCanceled, isTrue);
          expect(gotrue.grants, isEmpty);
        });

        test('no ID token -> Err, Supabase not called', () async {
          google.nullIdToken = true;
          final r = await repo(useNonce: ios).signInWithGoogle();

          expect(r, isA<Err<void>>());
          expectFailed(r, userCanceled: false);
          expect(gotrue.grants, isEmpty);
        });

        for (final code in [
          GoogleSignInExceptionCode.canceled,
          GoogleSignInExceptionCode.interrupted,
        ]) {
          test('${code.name} -> the cancelled sentence, userCanceled, no '
              'SDK text', () async {
            google.error = GoogleSignInException(
              code: code,
              description: sentinel,
              details: sentinel,
            );
            final r = await repo(useNonce: ios).signInWithGoogle();

            expectFailed(r, userCanceled: true, message: signInCanceledMessage);
            expect(gotrue.grants, isEmpty);
          });
        }

        for (final code in GoogleSignInExceptionCode.values.where(
          (c) =>
              c != GoogleSignInExceptionCode.canceled &&
              c != GoogleSignInExceptionCode.interrupted,
        )) {
          test('${code.name} -> the failed sentence, not a cancel, no SDK '
              'text', () async {
            google.error = GoogleSignInException(
              code: code,
              description: sentinel,
              details: sentinel,
            );
            final r = await repo(useNonce: ios).signInWithGoogle();

            expectFailed(r, userCanceled: false);
            expect(gotrue.grants, isEmpty);
          });
        }

        test('authenticate throws something else -> the failed sentence, '
            'no exception text', () async {
          google.error = StateError(sentinel);
          final r = await repo(useNonce: ios).signInWithGoogle();

          expectFailed(r, userCanceled: false);
          expect(gotrue.grants, isEmpty);
        });

        test('initialize fails -> the failed sentence, no exception text, '
            'Supabase not called', () async {
          google.initError = PlatformException(
            code: 'sign_in_failed',
            message: sentinel,
            details: sentinel,
          );
          final r = await repo(useNonce: ios).signInWithGoogle();

          expectFailed(r, userCanceled: false);
          expect(google.authenticateCalls, 0);
          expect(gotrue.grants, isEmpty);
        });

        test('Supabase refuses the token (e.g. its audience) -> the failed '
            'sentence; no GoTrue text, token, audience or client id', () async {
          gotrue.rejectWith =
              'Unacceptable audience in id_token: [$googleWebClient] $sentinel';
          final r = await repo(useNonce: ios).signInWithGoogle();

          expect(gotrue.grants, hasLength(1), reason: 'Supabase not called');
          final f = expectFailed(r, userCanceled: false);
          final token = gotrue.grants.single['id_token'] as String;
          for (final leak in [
            token,
            ...token.split('.'),
            googleWebClient,
            'web-client-123',
            'audience',
            'Unacceptable',
          ]) {
            expect(f.message, isNot(contains(leak)));
          }
        });

        test(
          'Supabase unreachable -> the offline message, no raw text',
          () async {
            gotrue.offline = true;
            final r = await repo(useNonce: ios).signInWithGoogle();

            expect(r, isA<Err<void>>());
            final message = (r as Err<void>).failure.message;
            expect(message, offlineMessage);
          },
        );
      });
    }

    test('iOS: Supabase\'s "Nonces mismatch" -> ProviderFailure with the '
        'fixed sentence', () async {
      // A token whose nonce is not the hash of what the repository sends.
      platform(ios: true);
      final auth = repo(useNonce: true);
      // Swap the SDK after initialize so the token carries a foreign nonce.
      expect(await auth.signInWithGoogle(), isA<Ok<void>>());
      google.inits.add(
        InitParameters(
          serverClientId: googleWebClient,
          nonce: sha256hex('someone-else'),
        ),
      );
      final r = await auth.signInWithGoogle();

      expect(r, isA<Err<void>>());
      final f = (r as Err<void>).failure;
      expect(f, isA<ProviderFailure>());
      expect(f.message, signInFailedMessage);
    });
  });
}

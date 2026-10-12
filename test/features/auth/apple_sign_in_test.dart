// Sign in with Apple through the real SupabaseAuthRepository, written from the
// contract (2026-10-12), never from the code.
//
// Both sides are stand-ins, because the real ones cannot run here:
// - Apple: a handler on the plugin's own method channel
//   (sign_in_with_apple_platform_interface 2.0.0: 'performAuthorizationRequest'
//   with [{type, nonce, scopes}], answering {type: appleid, authorizationCode,
//   identityToken, email}). Like the native SDK it embeds the nonce it is handed
//   in the identity token, and reports a cancel as
//   PlatformException('authorization-error/canceled').
// - Supabase: the real SupabaseClient over GoTrueStandIn, which applies GoTrue's
//   id_token nonce rules (sha256hex(request nonce) must equal the token nonce).
//
// NOT covered, and cannot be locally: a real Apple-signed token accepted by a
// real Supabase Auth with the Apple provider. That is verified on a device.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/google_sign_in_stand_ins.dart';

const sentinel = 'SENTINEL-a91c-raw-apple-text';
const channel = MethodChannel('com.aboutyou.dart_packages.sign_in_with_apple');

/// The native Sign in with Apple sheet, as far as SIS sees it.
class FakeApple {
  /// Every authorization request, as the plugin serialised it.
  final requests = <Map<Object?, Object?>>[];

  /// The email Apple puts in the identity token.
  String tokenEmail = 'ann@mail.test';

  /// The email field of the credential (Apple sends it on first sign-in only).
  String? credentialEmail;

  /// Thrown instead of answering, as the native side reports an error.
  PlatformException? error;
  bool nullToken = false;
  final tokens = <String>[];

  Future<Object?> handle(MethodCall call) async {
    if (call.method != 'performAuthorizationRequest') {
      throw MissingPluginException(call.method);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final req = (call.arguments as List).single as Map<Object?, Object?>;
    requests.add(req);
    if (error != null) throw error!;
    final nonce = req['nonce'] as String?;
    final token = [
      b64Json({'alg': 'RS256', 'kid': 'apple'}),
      b64Json({
        'iss': 'https://appleid.apple.com',
        'aud': 'com.esd.sis',
        'sub': 'apple-user-1',
        'email': tokenEmail,
        'email_verified': true,
        'nonce': ?nonce,
      }),
      'c2ln',
    ].join('.');
    tokens.add(token);
    return <String, Object?>{
      'type': 'appleid',
      'userIdentifier': 'apple-user-1',
      'authorizationCode': 'auth-code-1',
      'identityToken': nullToken ? null : token,
      'email': credentialEmail,
    };
  }
}

ProviderFailure expectProvider(
  Result<void> r, {
  required bool userCanceled,
  required String message,
}) {
  expect(r, isA<Err<void>>(), reason: '$r');
  final f = (r as Err<void>).failure;
  expect(f, isA<ProviderFailure>(), reason: '$f');
  expect(f.message, message);
  expect(f.message, isNot(contains(sentinel)));
  expect((f as ProviderFailure).userCanceled, userCanceled);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoTrueStandIn gotrue;
  late FakeApple apple;
  late FakeGooglePlatform google;
  final clients = <SupabaseClient>[];

  SupabaseClient client() {
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
    return c;
  }

  // iOS production wiring: useNonce true (Google's iOS nonce).
  SupabaseAuthRepository repo() => SupabaseAuthRepository(
    client(),
    GoogleSignIn.instance,
    googleWebClientId: googleWebClient,
    useNonce: true,
  );

  setUp(() {
    gotrue = GoTrueStandIn();
    apple = FakeApple();
    GoogleSignInPlatform.instance = google = FakeGooglePlatform(ios: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, apple.handle);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
  });

  test('Ok: Apple gets sha256hex(raw), Supabase gets raw with Apple\'s token; '
      'email scope only; Google untouched', () async {
    final r = await repo().signInWithApple();

    expect(r, isA<Ok<void>>(), reason: '$r');
    expect(apple.requests, hasLength(1));
    final req = apple.requests.single;
    expect(req['scopes'], ['email'], reason: 'email scope only');
    final hashed = req['nonce'] as String?;
    expect(hashed, matches(RegExp(r'^[0-9a-f]{64}$')));

    expect(gotrue.grants, hasLength(1));
    final grant = gotrue.grants.single;
    expect(grant['provider'], 'apple');
    expect(grant['id_token'], apple.tokens.single);
    final raw = grant['nonce'] as String?;
    expect(raw, isNotNull, reason: 'the raw nonce never reached Supabase');
    expect(raw, isNot(hashed), reason: 'Supabase got the hash, not the raw');
    expect(sha256hex(raw!), hashed);
    expect(google.authenticateCalls, 0, reason: 'Google sign-in ran');
  });

  test('a fresh nonce on every attempt, on one repository', () async {
    final auth = repo();
    expect(await auth.signInWithApple(), isA<Ok<void>>());
    expect(await auth.signInWithApple(), isA<Ok<void>>());
    expect(await auth.signInWithApple(), isA<Ok<void>>());

    final hashed = apple.requests.map((r) => r['nonce']).toSet();
    final raws = gotrue.grants.map((g) => g['nonce']).toSet();
    expect(hashed, hasLength(3), reason: 'Apple saw a reused nonce');
    expect(raws, hasLength(3), reason: 'Supabase saw a reused nonce');
  });

  group('hidden (relay) email: refused on the phone, no request', () {
    for (final email in [
      'x7f2k9@privaterelay.appleid.com',
      'X7F2K9@PrivateRelay.AppleID.com',
    ]) {
      test(email, () async {
        apple.tokenEmail = email;
        final r = await repo().signInWithApple();

        expect(r, isA<Err<void>>(), reason: '$r');
        expect((r as Err<void>).failure, isA<HiddenEmailFailure>());
        expect(gotrue.grants, isEmpty, reason: 'Supabase was asked');
        expect(gotrue.others, isEmpty, reason: 'another request was made');
      });
    }

    test('read from the token, not the credential\'s email field', () async {
      apple.tokenEmail = 'x7f2k9@privaterelay.appleid.com';
      apple.credentialEmail = 'ann@mail.test';
      final r = await repo().signInWithApple();

      expect((r as Err<void>).failure, isA<HiddenEmailFailure>());
      expect(gotrue.grants, isEmpty);
    });

    test('control: a real address that merely contains the relay domain '
        'reaches Supabase', () async {
      apple.tokenEmail = 'ann@privaterelay.appleid.com.example.test';
      final r = await repo().signInWithApple();

      expect(r, isA<Ok<void>>(), reason: '$r');
      expect(gotrue.grants, hasLength(1));
    });
  });

  test('cancel -> ProviderFailure(the cancelled sentence, userCanceled), '
      'Supabase not called', () async {
    apple.error = PlatformException(
      code: 'authorization-error/canceled',
      message: sentinel,
    );
    expectProvider(
      await repo().signInWithApple(),
      userCanceled: true,
      message: signInCanceledMessage,
    );
    expect(gotrue.grants, isEmpty);
  });

  for (final code in [
    'authorization-error/failed',
    'authorization-error/unknown',
    'not-supported',
  ]) {
    test('Apple error $code -> the failed sentence, not a cancel', () async {
      apple.error = PlatformException(code: code, message: sentinel);
      expectProvider(
        await repo().signInWithApple(),
        userCanceled: false,
        message: signInFailedMessage,
      );
      expect(gotrue.grants, isEmpty);
    });
  }

  test(
    'no identity token -> the failed sentence, Supabase not called',
    () async {
      apple.nullToken = true;
      expectProvider(
        await repo().signInWithApple(),
        userCanceled: false,
        message: signInFailedMessage,
      );
      expect(gotrue.grants, isEmpty);
    },
  );

  test('Supabase 403 (the sign-up hook refused) -> DeniedFailure', () async {
    gotrue.replyWith = (
      403,
      {'code': 403, 'error_code': 'unknown', 'msg': 'not invited'},
    );
    final r = await repo().signInWithApple();

    expect(r, isA<Err<void>>(), reason: '$r');
    expect((r as Err<void>).failure, isA<DeniedFailure>());
    expect(gotrue.grants, hasLength(1));
  });

  test(
    'another Supabase auth error -> the failed sentence, no raw text',
    () async {
      gotrue.rejectWith = 'Bad ID token $sentinel';
      expectProvider(
        await repo().signInWithApple(),
        userCanceled: false,
        message: 'Sign-in failed. Please try again.',
      );
      expect(gotrue.grants, hasLength(1));
    },
  );

  // The seam: real repository -> real SessionController.
  group('repository -> controller', () {
    Future<(ProviderContainer, SessionState)> viaController() async {
      final c = ProviderContainer.test(
        overrides: [
          authRepositoryProvider.overrideWithValue(repo()),
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: 'http://supabase.test',
              supabasePublishableKey: 'publishable-key',
              googleWebClientId: googleWebClient,
            ),
          ),
        ],
      );
      await c.read(sessionControllerProvider.future);
      await c.read(sessionControllerProvider.notifier).signInWithApple();
      await Future<void>.delayed(Duration.zero);
      return (c, c.read(sessionControllerProvider).requireValue);
    }

    test('relay email -> SignedOut(hiddenEmail)', () async {
      apple.tokenEmail = 'x7f2k9@privaterelay.appleid.com';
      final (_, s) = await viaController();
      expect(s, isA<SignedOut>());
      expect((s as SignedOut).hiddenEmail, isTrue);
    });

    test('403 -> Denied', () async {
      gotrue.replyWith = (403, {'code': 403, 'msg': 'not invited'});
      final (_, s) = await viaController();
      expect(s, isA<Denied>());
    });

    test('cancel -> SignedOut, not hidden', () async {
      apple.error = PlatformException(code: 'authorization-error/canceled');
      final (_, s) = await viaController();
      expect(s, isA<SignedOut>());
      expect((s as SignedOut).hiddenEmail, isFalse);
    });
  });
}

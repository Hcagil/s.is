// The sign-up gate as the app sees it (2026-10-05, from the contract).
//
// When the before-user-created hook refuses an address, GoTrue answers the
// id_token grant with HTTP 403 {"code":403,"error_code":"unknown",
// "msg":"not invited"} and creates nobody. Contract:
//
// - SupabaseAuthRepository.signInWithGoogle maps an AuthException with
//   statusCode '403' to DeniedFailure, and any other status to
//   ProviderFailure(signInFailedMessage).
// - SessionController.signIn with a DeniedFailure goes to Denied(), which the
//   gate shows as the existing "Access denied" screen.
//
// The real repository and controller run over the GoTrue stand-in of
// google_sign_in_nonce_test; the refusal body is the one local Auth returns
// (test/integration/signup_gate_test.dart proves that against real Auth).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/fakes.dart';
import '../../support/google_sign_in_stand_ins.dart';

const sentinel = 'SENTINEL-9d2e-raw-exception-text';
const notInvited = <String, Object?>{
  'code': 403,
  'error_code': 'unknown',
  'msg': 'not invited',
};
const config = RuntimeConfig(
  supabaseUrl: 'http://supabase.test',
  supabasePublishableKey: 'publishable-key',
  googleWebClientId: googleWebClient,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoTrueStandIn gotrue;
  late SupabaseClient client;

  setUp(() {
    gotrue = GoTrueStandIn();
    GoogleSignInPlatform.instance = FakeGooglePlatform(ios: false);
    client = SupabaseClient(
      config.supabaseUrl,
      config.supabasePublishableKey,
      httpClient: gotrue.client,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
  });
  tearDown(() => client.dispose());

  SupabaseAuthRepository repo() => SupabaseAuthRepository(
    client,
    GoogleSignIn.instance,
    googleWebClientId: googleWebClient,
  );

  Failure failureOf(Result<void> r) {
    expect(r, isA<Err<void>>(), reason: '$r');
    return (r as Err<void>).failure;
  }

  group('SupabaseAuthRepository.signInWithGoogle', () {
    test('403 "not invited" from Auth -> DeniedFailure', () async {
      gotrue.replyWith = (403, notInvited);
      final f = failureOf(await repo().signInWithGoogle());

      expect(f, isA<DeniedFailure>());
      expect(gotrue.grants, hasLength(1));
      expect(repo().hasSession, isFalse, reason: 'a refusal holds no session');
    });

    test('any 403 is the gate, whatever its text -> DeniedFailure', () async {
      gotrue.replyWith = (
        403,
        {'code': 403, 'error_code': 'unknown', 'msg': sentinel},
      );
      final f = failureOf(await repo().signInWithGoogle());

      expect(f, isA<DeniedFailure>());
      expect(f.message, isNot(contains(sentinel)));
    });

    for (final status in [400, 401, 404, 409, 422, 429]) {
      test('$status (even saying "not invited") -> ProviderFailure, '
          'the failed sentence, not Denied', () async {
        gotrue.replyWith = (
          status,
          {'code': status, 'error_code': 'unknown', 'msg': 'not invited'},
        );
        final f = failureOf(await repo().signInWithGoogle());

        expect(f, isA<ProviderFailure>());
        expect(f.message, signInFailedMessage);
        expect((f as ProviderFailure).userCanceled, isFalse);
      });
    }

    // GoTrue's 5xx is retryable: it was already a NetworkFailure ("no
    // connection") before the gate, and stays one -- never Denied.
    for (final status in [500, 502]) {
      test('$status saying "not invited" -> not Denied', () async {
        gotrue.replyWith = (
          status,
          {'code': status, 'error_code': 'unknown', 'msg': 'not invited'},
        );
        final f = failureOf(await repo().signInWithGoogle());

        expect(f, isNot(isA<DeniedFailure>()));
        expect(f, isA<NetworkFailure>());
      });
    }
  });

  group('SessionController.signIn', () {
    Future<SessionState> signIn(List<Override> overrides) async {
      final c = ProviderContainer.test(
        overrides: [
          ...overrides,
          runtimeConfigProvider.overrideWithValue(config),
        ],
      );
      await c.read(sessionControllerProvider.future);
      await c.read(sessionControllerProvider.notifier).signIn();
      // Let any auth-state event the attempt raised land before reading.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return c.read(sessionControllerProvider).requireValue;
    }

    test('DeniedFailure -> Denied (fake repository)', () async {
      final s = await signIn([
        authRepositoryProvider.overrideWithValue(
          FakeAuth(signInResult: const Err(DeniedFailure())),
        ),
      ]);
      expect(s, isA<Denied>());
    });

    test('seam: real repository, Auth answers 403 -> Denied', () async {
      gotrue.replyWith = (403, notInvited);
      final s = await signIn([
        authRepositoryProvider.overrideWithValue(repo()),
      ]);
      expect(s, isA<Denied>());
      expect(gotrue.grants, hasLength(1));
    });

    test('seam: real repository, Auth answers 400 -> SessionError, '
        'not Denied', () async {
      gotrue.replyWith = (
        400,
        {'code': 400, 'error_code': 'validation_failed', 'msg': sentinel},
      );
      final s = await signIn([
        authRepositoryProvider.overrideWithValue(repo()),
      ]);
      expect(s, isA<SessionError>());
      expect((s as SessionError).reason, signInFailedMessage);
    });
  });

  group('the screen the gate shows', () {
    Future<void> tapSignIn(WidgetTester t) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(repo()),
            runtimeConfigProvider.overrideWithValue(config),
          ],
          child: const SisApp(),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Continue with Google'));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();
    }

    testWidgets('a refused sign-up shows "Access denied"', (t) async {
      gotrue.replyWith = (403, notInvited);
      await tapSignIn(t);

      expect(find.text('Access denied'), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}

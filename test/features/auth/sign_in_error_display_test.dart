// What the user reads when sign-in fails, across the seam: the real
// SupabaseAuthRepository (over the Google and GoTrue stand-ins of
// google_sign_in_nonce_test) -> the real SessionController -> the gate in
// SisApp. Every failure plants a sentinel in the raw exception or response;
// the screen must show only the fixed sentence.
//
// Not covered here: main()'s own catch (it needs dart-defines, Supabase and
// Firebase to run). What is covered is that the startup screen turns the
// StartupFailure main() hands startupErrorProvider into the localised text.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/startup_failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/google_sign_in_stand_ins.dart';
import '../../support/l10n.dart';

const sentinel = 'SENTINEL-51c9-raw-exception-text';
const startupSentence = 'SIS could not start. Please try again.';
const config = RuntimeConfig(
  supabaseUrl: 'http://supabase.test',
  supabasePublishableKey: 'publishable-key',
  googleWebClientId: googleWebClient,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoTrueStandIn gotrue;
  late FakeGooglePlatform google;
  late SupabaseClient client;

  setUp(() {
    gotrue = GoTrueStandIn();
    GoogleSignInPlatform.instance = google = FakeGooglePlatform(ios: false);
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

  List<Override> overrides() => [
    authRepositoryProvider.overrideWithValue(
      SupabaseAuthRepository(
        client,
        GoogleSignIn.instance,
        googleWebClientId: googleWebClient,
        useNonce: false,
      ),
    ),
    runtimeConfigProvider.overrideWithValue(config),
  ];

  Future<SessionState> signIn() async {
    final c = ProviderContainer.test(overrides: overrides());
    await c.read(sessionControllerProvider.future);
    await c.read(sessionControllerProvider.notifier).signIn();
    await Future<void>.delayed(Duration.zero);
    return c.read(sessionControllerProvider).requireValue;
  }

  group('repository -> controller', () {
    test(
      'Supabase refuses the token -> SessionError(the failed sentence)',
      () async {
        gotrue.rejectWith = 'Unacceptable audience: $googleWebClient $sentinel';
        final s = await signIn();

        expect(s, isA<SessionError>());
        expect((s as SessionError).reason, signInFailedMessage);
      },
    );

    test('Google SDK error -> SessionError(the failed sentence)', () async {
      google.error = const GoogleSignInException(
        code: GoogleSignInExceptionCode.clientConfigurationError,
        description: sentinel,
      );
      final s = await signIn();

      expect(s, isA<SessionError>());
      expect((s as SessionError).reason, signInFailedMessage);
    });

    test('cancel -> SignedOut(reason: the cancelled sentence)', () async {
      google.error = const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: sentinel,
      );
      final s = await signIn();

      expect(s, isA<SignedOut>());
      expect((s as SignedOut).reason, signInCanceledMessage);
    });
  });

  group('the scope-authorization step (0.30.8)', () {
    // authenticate() succeeds; the exception comes from the next step, the
    // scope consent. It must be mapped like every other sign-in error, and
    // the controller must leave its loading state.
    Future<(SessionState, ProviderContainer)> signInKeeping() async {
      final c = ProviderContainer.test(overrides: overrides());
      await c.read(sessionControllerProvider.future);
      await c
          .read(sessionControllerProvider.notifier)
          .signIn()
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      return (c.read(sessionControllerProvider).requireValue, c);
    }

    test('dismissed consent -> SignedOut(the cancelled sentence)', () async {
      google.scopeError = const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: sentinel,
      );
      final (s, c) = await signInKeeping();
      expect(google.scopeCalls, greaterThan(0), reason: 'the step was reached');
      expect(s, isA<SignedOut>());
      expect((s as SignedOut).reason, signInCanceledMessage);
      expect(c.read(sessionControllerProvider).isLoading, isFalse);
    });

    test('any other failure -> SessionError(the failed sentence)', () async {
      google.scopeError = const GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
        description: sentinel,
      );
      final (s, c) = await signInKeeping();
      expect(google.scopeCalls, greaterThan(0));
      expect(s, isA<SessionError>());
      expect((s as SessionError).reason, signInFailedMessage);
      expect(c.read(sessionControllerProvider).isLoading, isFalse);
      expect(s, isNot(isA<SessionLoading>()));
    });
  });

  group('the screen the gate shows', () {
    Future<void> tapSignIn(WidgetTester t) async {
      await t.pumpWidget(
        ProviderScope(overrides: overrides(), child: const SisApp()),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Continue with Google'));
      // The stand-ins answer after real timers (a platform call, a request).
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();
    }

    testWidgets('Supabase refuses: the failed sentence, nothing raw', (
      t,
    ) async {
      gotrue.rejectWith = 'Unacceptable audience: $googleWebClient $sentinel';
      await tapSignIn(t);

      expect(gotrue.grants, hasLength(1));
      expect(find.text(signInFailedMessage), findsOneWidget);
      expect(find.textContaining(sentinel), findsNothing);
      expect(find.textContaining(googleWebClient), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('cancelled: back on sign-in, the cancelled sentence', (
      t,
    ) async {
      google.error = const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: sentinel,
      );
      await tapSignIn(t);

      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text(signInCanceledMessage), findsOneWidget);
      expect(find.textContaining(sentinel), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('startup failure', () {
    // main() hands the gate a reason code, never a sentence; the screen turns
    // it into the localised statusStartBootstrap.
    for (final (name, locale, l, other) in [
      ('en', const Locale('en'), l10nEn, l10nTr),
      ('tr', const Locale('tr'), l10nTr, l10nEn),
    ]) {
      testWidgets('StartupFailedScreen(bootstrap) shows the $name sentence', (
        t,
      ) async {
        await t.pumpWidget(
          localizedApp(
            locale: locale,
            home: const StartupFailedScreen(StartupFailure.bootstrap),
          ),
        );
        expect(find.textContaining(l.statusStartBootstrap), findsOneWidget);
        expect(find.textContaining(other.statusStartBootstrap), findsNothing);
        expect(find.textContaining('bootstrap'), findsNothing);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('the gate shows startupErrorProvider as the sentence', (
      t,
    ) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            startupErrorProvider.overrideWithValue(StartupFailure.bootstrap),
          ],
          child: const SisApp(),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byType(StartupFailedScreen), findsOneWidget);
      expect(find.textContaining(startupSentence), findsOneWidget);
    });
  });
}

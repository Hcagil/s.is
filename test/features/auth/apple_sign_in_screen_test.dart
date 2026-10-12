// The Apple button and the hidden-email line, written from the contract
// (2026-10-12): the gate in SisApp with the real SessionController, a fake
// only at the repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/apple_button.dart';
import 'package:sis/features/auth/presentation/sign_in_screen.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const hiddenEn =
    "SIS needs your real email address. In Apple's sign-in choose Share My "
    'Email and try again.';
const hiddenTr =
    'SIS gerçek e-posta adresinizi gerektirir. Apple girişinde E-postamı '
    "Paylaş'ı seçip tekrar deneyin.";
final appleButton = find.byKey(const ValueKey('apple-sign-in'));
final googleButton = find.text('Continue with Google');
final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
final android = TargetPlatformVariant.only(TargetPlatform.android);

Widget app(FakeAuth auth) => ProviderScope(
  overrides: [
    authRepositoryProvider.overrideWithValue(auth),
    runtimeConfigProvider.overrideWithValue(config),
  ],
  child: const SisApp(),
);

Future<void> tapApple(WidgetTester t) async {
  await t.tap(appleButton);
  await t.pumpAndSettle();
}

void main() {
  group('sign-in screen', () {
    testWidgets('iOS: Apple button below Google', (t) async {
      await t.pumpWidget(app(FakeAuth()));
      await t.pumpAndSettle();

      expect(googleButton, findsOneWidget);
      expect(appleButton, findsOneWidget);
      expect(
        t.getTopLeft(appleButton).dy,
        greaterThanOrEqualTo(t.getBottomLeft(googleButton).dy),
        reason: 'the Apple button is not below Google',
      );
    }, variant: ios);

    testWidgets('Android: Google only', (t) async {
      await t.pumpWidget(app(FakeAuth()));
      await t.pumpAndSettle();

      expect(googleButton, findsOneWidget);
      expect(appleButton, findsNothing);
    }, variant: android);

    testWidgets('iOS: the Apple button runs Apple sign-in, not Google', (
      t,
    ) async {
      final auth = FakeAuth(
        signInResult: const Err(ProviderFailure('google ran')),
      )..appleResult = const Err(HiddenEmailFailure());
      await t.pumpWidget(app(auth));
      await t.pumpAndSettle();
      await tapApple(t);

      expect(auth.appleCalls, 1);
      expect(find.text('google ran'), findsNothing);
    }, variant: ios);

    for (final (name, locale, line, other) in [
      ('en', const Locale('en'), hiddenEn, hiddenTr),
      ('tr', const Locale('tr'), hiddenTr, hiddenEn),
    ]) {
      testWidgets('iOS: hidden email -> stays on sign-in with the $name line', (
        t,
      ) async {
        t.platformDispatcher.localesTestValue = [locale];
        addTearDown(t.platformDispatcher.clearLocalesTestValue);
        final auth = FakeAuth()..appleResult = const Err(HiddenEmailFailure());
        await t.pumpWidget(app(auth));
        await t.pumpAndSettle();
        await tapApple(t);

        expect(find.byType(SignInScreen), findsOneWidget);
        expect(appleButton, findsOneWidget);
        expect(find.text(line), findsOneWidget);
        expect(find.text(other), findsNothing);
      }, variant: ios);

      testWidgets('SignInScreen(hiddenEmail: true) shows exactly the $name '
          'line', (t) async {
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              authRepositoryProvider.overrideWithValue(FakeAuth()),
              runtimeConfigProvider.overrideWithValue(config),
            ],
            child: localizedApp(
              locale: locale,
              home: const SignInScreen(hiddenEmail: true),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text(line), findsOneWidget);
        expect(find.text(other), findsNothing);
      });
    }

    testWidgets('without hiddenEmail neither line shows', (t) async {
      await t.pumpWidget(app(FakeAuth()));
      await t.pumpAndSettle();
      expect(find.text(hiddenEn), findsNothing);
      expect(find.text(hiddenTr), findsNothing);
    }, variant: ios);

    testWidgets('iOS: Apple refused by the server -> the Denied screen', (
      t,
    ) async {
      final auth = FakeAuth()..appleResult = const Err(DeniedFailure());
      await t.pumpWidget(app(auth));
      await t.pumpAndSettle();
      await tapApple(t);

      expect(find.textContaining('not currently approved'), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
    }, variant: ios);

    testWidgets('iOS: Apple fails -> the error screen with the sentence', (
      t,
    ) async {
      final auth = FakeAuth()
        ..appleResult = const Err(
          ProviderFailure('Sign-in failed. Please try again.'),
        );
      await t.pumpWidget(app(auth));
      await t.pumpAndSettle();
      await tapApple(t);

      expect(find.byType(SignInScreen), findsNothing);
      expect(find.text('Sign-in failed. Please try again.'), findsOneWidget);
    }, variant: ios);
  });

  group('StatusScreen.replaced', () {
    Future<List<String>> pump(
      WidgetTester t, {
      Widget Function(String, VoidCallback)? builder = appleSignInButton,
    }) async {
      final calls = <String>[];
      await t.pumpWidget(
        localizedApp(
          home: StatusScreen.replaced(
            onSignIn: () async => calls.add('google'),
            onSignInApple: () async => calls.add('apple'),
            appleButton: builder,
            unsentDeleted: 2,
          ),
        ),
      );
      await t.pumpAndSettle();
      return calls;
    }

    testWidgets('iOS: the Apple button shows and runs onSignInApple', (
      t,
    ) async {
      final calls = await pump(t);
      expect(appleButton, findsOneWidget);
      await t.tap(appleButton);
      await t.pumpAndSettle();
      expect(calls, ['apple']);
    }, variant: ios);

    testWidgets('Android: no Apple button', (t) async {
      await pump(t);
      expect(appleButton, findsNothing);
    }, variant: android);

    testWidgets('iOS without a builder: no Apple button', (t) async {
      await pump(t, builder: null);
      expect(appleButton, findsNothing);
    }, variant: ios);
  });
}

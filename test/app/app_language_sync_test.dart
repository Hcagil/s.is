// The signed-in gate tells the server the language the app shows.
//
// Written from the contract, not the code: appLanguageSyncProvider(code) is
// watched by the signed-in gate with the shown locale's languageCode (the
// Settings choice, or the phone's when Settings is System). It writes once
// per sign-in or start, again whenever the shown language changes, never for
// a signed-out phone, and a failure is silent (the next start tries again).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/auth/application/session_controller.dart';

import '../support/design_fakes.dart';

void main() {
  late DesignProfile profile;
  late DesignAuth auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    profile = DesignProfile();
    auth = DesignAuth(session: true);
  });

  Future<void> start(
    WidgetTester t, {
    AppLanguage language = AppLanguage.system,
  }) async {
    await t.pumpWidget(
      designApp(
        auth: auth,
        profile: profile,
        extra: [
          appearanceStoreProvider.overrideWithValue(
            const SharedPrefsAppearanceStore(),
          ),
          initialAppearanceProvider.overrideWithValue(
            AppearanceSettings(language: language),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();
  }

  ProviderContainer container(WidgetTester t) =>
      ProviderScope.containerOf(t.element(find.byType(SisApp)));

  void phone(WidgetTester t, String code) {
    t.platformDispatcher.localesTestValue = [Locale(code)];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
  }

  testWidgets('Settings English: one write of en at start', (t) async {
    phone(t, 'tr');
    await start(t, language: AppLanguage.en);
    expect(profile.appLanguages, ['en']);
  });

  testWidgets('Settings Turkish on an English phone: tr', (t) async {
    phone(t, 'en');
    await start(t, language: AppLanguage.tr);
    expect(profile.appLanguages, ['tr']);
  });

  testWidgets('Settings System follows the phone: tr phone writes tr', (
    t,
  ) async {
    phone(t, 'tr');
    await start(t);
    expect(profile.appLanguages, ['tr']);
  });

  testWidgets('Settings System follows the phone: en phone writes en', (
    t,
  ) async {
    phone(t, 'en');
    await start(t);
    expect(profile.appLanguages, ['en']);
  });

  testWidgets('a language change in Settings writes again, once', (t) async {
    phone(t, 'en');
    await start(t, language: AppLanguage.en);
    final look = container(t).read(appearanceProvider.notifier);

    await look.setLanguage(AppLanguage.tr);
    await t.pumpAndSettle();
    expect(profile.appLanguages, ['en', 'tr']);

    // Rebuilds that do not change the shown language write nothing.
    await look.setTheme(AppThemeId.ocean);
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 1));
    expect(profile.appLanguages, ['en', 'tr']);

    // System on an English phone shows English again: one more write.
    await look.setLanguage(AppLanguage.system);
    await t.pumpAndSettle();
    expect(profile.appLanguages, ['en', 'tr', 'en']);
  });

  testWidgets('choosing the language already shown writes nothing new', (
    t,
  ) async {
    phone(t, 'en');
    await start(t);
    await container(t)
        .read(appearanceProvider.notifier)
        .setLanguage(AppLanguage.en);
    await t.pumpAndSettle();
    expect(profile.appLanguages, ['en']);
  });

  testWidgets('a signed-out phone writes nothing; signing in writes', (
    t,
  ) async {
    auth = DesignAuth();
    phone(t, 'en');
    await start(t, language: AppLanguage.tr);
    expect(profile.appLanguages, isEmpty, reason: 'signed out');

    // Its sign-in waits on a timer: pump the clock rather than awaiting it.
    final signedIn = auth.signInWithGoogle();
    await t.pumpAndSettle();
    await signedIn;
    expect(profile.appLanguages, ['tr']);

    await auth.signOut();
    await t.pumpAndSettle();
    // Its sign-in waits on a timer: pump the clock rather than awaiting it.
    final again = auth.signInWithGoogle();
    await t.pumpAndSettle();
    await again;
    expect(profile.appLanguages, ['tr', 'tr'], reason: 'once per sign-in');
  });

  testWidgets('a failed write is silent and the next start tries again', (
    t,
  ) async {
    profile.appLanguageResult = const Err(NetworkFailure('offline'));
    phone(t, 'en');
    await start(t, language: AppLanguage.en);
    expect(profile.appLanguages, ['en']);
    expect(t.takeException(), isNull);
    expect(find.text('offline'), findsNothing, reason: 'failure is silent');
    expect(container(t).read(sessionControllerProvider).hasError, isFalse);

    // A new start (a fresh ProviderScope) writes again.
    await t.pumpWidget(const SizedBox());
    await start(t, language: AppLanguage.en);
    expect(profile.appLanguages, ['en', 'en']);
  });
}

// Seam: the appearance pages -> AppearanceController -> SharedPrefsAppearanceStore
// -> SharedPreferences, and back through main() on the next start. Choices are
// made through the pages as production mounts them; the app is then started
// again by main() itself over the same preferences, and the very first frame
// must already carry them (no flash of the default theme).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/main.dart' as entry;

import '../support/design_fakes.dart';

Finder byKey(String k) => find.byKey(ValueKey(k));

Future<void> reveal(WidgetTester t, Finder f) async {
  for (final dy in [-150.0, 150.0]) {
    for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
      await t.drag(find.byType(Scaffold).last, Offset(0, dy));
      await t.pumpAndSettle();
    }
  }
  await t.ensureVisible(f);
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder f) async {
  await reveal(t, f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String k) => tap(t, byKey(k));

Future<void> back(WidgetTester t) async {
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
}

BuildContext appContext(WidgetTester t) =>
    t.element(find.byType(Navigator).first);

void expectApplied(WidgetTester t, String when) {
  final ctx = appContext(t);
  final theme = Theme.of(ctx);
  expect(
    theme.colorScheme.primary,
    sisBrandFor(AppThemeId.ocean, Brightness.light).brand,
    reason: '$when: theme',
  );
  expect(theme.textTheme.bodyMedium?.fontFamily, 'Manrope', reason: when);
  expect(Localizations.localeOf(ctx), const Locale('tr'), reason: when);
  expect(
    MediaQuery.textScalerOf(ctx).scale(10),
    closeTo(8.8, 1e-6),
    reason: '$when: app text size',
  );
}

void main() {
  testWidgets('choices made on the pages persist and apply on the first '
      'frame of the next start', (t) async {
    SharedPreferences.setMockInitialValues({});
    const store = SharedPrefsAppearanceStore();
    // As main.dart does: read before the app is mounted.
    final initial = await store.load();
    await t.pumpWidget(
      designApp(
        auth: DesignAuth(session: true),
        extra: [
          appearanceStoreProvider.overrideWithValue(store),
          initialAppearanceProvider.overrideWithValue(initial),
        ],
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tapKey(t, 'home-settings');
    await tapKey(t, 'settings-appearance');
    await tapKey(t, 'theme-ocean');
    await back(t);

    await tapKey(t, 'settings-text-size');
    await tap(
      t,
      find.descendant(
        of: byKey('text-chat-size'),
        matching: find.text('Large'),
      ),
    );
    await tap(
      t,
      find.descendant(of: byKey('text-app-size'), matching: find.text('Small')),
    );
    await tapKey(t, 'text-system-font');
    await back(t);

    await tapKey(t, 'settings-language');
    await tapKey(t, 'language-tr');
    expectApplied(t, 'live');

    // The next start: main() reads the same preferences before runApp.
    await t.pumpWidget(const SizedBox());
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    await entry.main();
    await t.pump(); // the first frame, and only it

    expectApplied(t, 'first frame after restart');
    expect(
      await store.load(),
      const AppearanceSettings(
        themeId: AppThemeId.ocean,
        systemFont: false,
        chatTextSize: TextSize.large,
        appTextSize: TextSize.small,
        language: AppLanguage.tr,
      ),
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('main() with nothing stored starts on the defaults', (t) async {
    SharedPreferences.setMockInitialValues({});
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    await t.pumpWidget(const SizedBox());
    await entry.main();
    await t.pump();
    final ctx = appContext(t);
    expect(
      Theme.of(ctx).colorScheme.primary,
      sisBrandFor(AppThemeId.violet, Brightness.light).brand,
    );
    expect(MediaQuery.textScalerOf(ctx).scale(10), closeTo(10, 1e-6));
    await t.pumpWidget(const SizedBox());
  });
}

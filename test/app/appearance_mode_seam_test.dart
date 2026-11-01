// Seam: the Appearance page's light/dark row -> AppearanceController ->
// SharedPrefsAppearanceStore -> SharedPreferences, and SisApp's themeMode, as
// production mounts them (designApp); then main() again over the same
// preferences. Written from the contract, not the code.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/settings_row.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/presentation/chat_preview.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/main.dart' as entry;

import '../support/design_fakes.dart';

Finder byKey(String k) => find.byKey(ValueKey(k));

Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text));

Finder underContaining(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.textContaining(text));

const store = SharedPrefsAppearanceStore();

CustomTheme custom(String id, String name, CustomThemeMode mode) => CustomTheme(
  id: id,
  name: name,
  mode: mode,
  accent: 0xFF2E7D32,
  mine: 0xFF1B5E20,
  theirs: 0xFF263238,
);

Future<void> pumpApp(
  WidgetTester t, {
  AppearanceSettings initial = const AppearanceSettings(),
  bool tallPhone = true,
}) async {
  if (tallPhone) {
    t.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(411 * 3, 914 * 3);
    addTearDown(t.view.reset);
  }
  SharedPreferences.setMockInitialValues({});
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
}

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

Future<void> tapKey(WidgetTester t, String k) async {
  await reveal(t, byKey(k));
  await t.tap(byKey(k));
  await t.pumpAndSettle();
}

Future<void> openAppearance(WidgetTester t) async {
  await tapKey(t, 'home-settings');
  await tapKey(t, 'settings-appearance');
}

Future<void> openCard(WidgetTester t) async {
  await openAppearance(t);
  await tapKey(t, 'appearance-mode');
  expect(byKey('appearance-mode-card'), findsOneWidget);
}

// What the app asks for on the very frame after the tap. MaterialApp then
// cross-fades to it (Flutter's default theme animation).
ThemeMode asked(WidgetTester t) =>
    t.widget<MaterialApp>(find.byType(MaterialApp).first).themeMode!;

Brightness shown(WidgetTester t) =>
    Theme.of(t.element(find.byType(Navigator).first)).brightness;

AppearanceSettings look(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)))
        .read(appearanceProvider);

void phone(WidgetTester t, Brightness b) {
  t.platformDispatcher.platformBrightnessTestValue = b;
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
}

void main() {
  testWidgets('default: the first row reads System default and the app '
      'follows the phone brightness', (t) async {
    phone(t, Brightness.dark);
    await pumpApp(t);
    await openAppearance(t);
    expect(under('appearance-mode', 'Light or dark'), findsOneWidget);
    expect(under('appearance-mode', 'System default'), findsOneWidget);
    expect(
      t.getRect(byKey('appearance-mode')).top,
      lessThan(t.getRect(find.byType(ChatPreview).first).top),
      reason: 'the row comes before the chat preview',
    );
    expect(shown(t), Brightness.dark);

    t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await t.pumpAndSettle();
    expect(shown(t), Brightness.light);
  });

  testWidgets('Light/Dark apply in the same frame, the card stays open, '
      'the dim area closes it, and the choice survives a restart', (t) async {
    phone(t, Brightness.dark);
    await pumpApp(t);
    await openCard(t);
    for (final k in ['system', 'light', 'dark']) {
      expect(byKey('appearance-mode-$k'), findsOneWidget, reason: k);
    }
    expect(byKey('appearance-mode-note'), findsOneWidget);
    expect(under('appearance-mode-system', 'System default'), findsOneWidget);
    expect(under('appearance-mode-light', 'Light'), findsOneWidget);
    expect(under('appearance-mode-dark', 'Dark'), findsOneWidget);

    await t.tap(byKey('appearance-mode-light'));
    await t.pump(); // one frame, no settle
    expect(asked(t), ThemeMode.light, reason: 'same frame');
    await t.pumpAndSettle();
    expect(shown(t), Brightness.light);
    expect(byKey('appearance-mode-card'), findsOneWidget, reason: 'stays open');
    expect(under('appearance-mode', 'Light'), findsOneWidget);

    t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await t.tap(byKey('appearance-mode-dark'));
    await t.pump();
    expect(asked(t), ThemeMode.dark, reason: 'same frame');
    await t.pumpAndSettle();
    expect(shown(t), Brightness.dark);
    expect(look(t).mode, AppearanceMode.dark);
    expect((await store.load()).mode, AppearanceMode.dark);

    final size = t.view.physicalSize / t.view.devicePixelRatio;
    final card = t.getRect(byKey('appearance-mode-card'));
    // A point of the dim area, clear of the card.
    await t.tapAt(
      card.top > size.height / 2
          ? Offset(size.width / 2, card.top / 2)
          : Offset(size.width / 2, (card.bottom + size.height) / 2),
    );
    await t.pumpAndSettle();
    expect(byKey('appearance-mode-card'), findsNothing, reason: 'dim closes');
    expect(under('appearance-mode', 'Dark'), findsOneWidget);

    // The next start, by main() over the same preferences, on a light phone.
    await t.pumpWidget(const SizedBox());
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    await entry.main();
    await t.pump();
    expect(shown(t), Brightness.dark, reason: 'restored after restart');
    await t.pumpWidget(const SizedBox());
  });

  for (final (fixed, other, b, word) in [
    (CustomThemeMode.dark, AppearanceMode.light, Brightness.dark, 'dark'),
    (CustomThemeMode.light, AppearanceMode.dark, Brightness.light, 'light'),
  ]) {
    testWidgets('a custom theme fixed $word wins over choosing '
        '${other.name}, and the note says always $word', (t) async {
      phone(t, b == Brightness.dark ? Brightness.light : Brightness.dark);
      final theme = custom('c1', 'Mine', fixed);
      await pumpApp(
        t,
        initial: AppearanceSettings(customThemes: [theme], customThemeId: 'c1'),
      );
      expect(shown(t), b);
      await openCard(t);
      expect(
        underContaining('appearance-mode-note', '“Mine” is always $word'),
        findsOneWidget,
      );
      await t.tap(byKey('appearance-mode-${other.name}'));
      await t.pumpAndSettle();
      expect(asked(t), b == Brightness.dark ? ThemeMode.dark : ThemeMode.light);
      expect(look(t).mode, other, reason: 'the choice is still stored');
      expect(shown(t), b, reason: 'the fixed custom theme wins');
    });
  }

  testWidgets('an automatic custom theme follows the choice; the note '
      'names it', (t) async {
    phone(t, Brightness.light);
    final theme = custom('a1', 'Auto', CustomThemeMode.automatic);
    await pumpApp(
      t,
      initial: AppearanceSettings(customThemes: [theme], customThemeId: 'a1'),
    );
    await openCard(t);
    expect(
      under('appearance-mode-note', '“Auto” follows this choice.'),
      findsOneWidget,
    );
    await t.tap(byKey('appearance-mode-dark'));
    await t.pump();
    expect(asked(t), ThemeMode.dark, reason: 'same frame');
    await t.pumpAndSettle();
    expect(shown(t), Brightness.dark);
  });

  testWidgets('a built-in theme: the note says it keeps its own colours', (
    t,
  ) async {
    await pumpApp(t);
    await openCard(t);
    expect(
      underContaining('appearance-mode-note', 'keeps its own colors'),
      findsOneWidget,
    );
  });

  testWidgets('TR strings', (t) async {
    await pumpApp(
      t,
      initial: const AppearanceSettings(language: AppLanguage.tr),
    );
    await openAppearance(t);
    expect(under('appearance-mode', 'Açık veya koyu'), findsOneWidget);
    expect(under('appearance-mode', 'Sistem varsayılanı'), findsOneWidget);
    await tapKey(t, 'appearance-mode');
    expect(
      under('appearance-mode-system', 'Sistem varsayılanı'),
      findsOneWidget,
    );
    expect(under('appearance-mode-light', 'Açık'), findsOneWidget);
    expect(under('appearance-mode-dark', 'Koyu'), findsOneWidget);
  });

  for (final lang in [AppLanguage.en, AppLanguage.tr]) {
    for (final mode in CustomThemeMode.values) {
      testWidgets('360 wide, ${lang.name}, custom ${mode.name}: row, card, '
          'value and note do not overflow', (t) async {
        t.view
          ..devicePixelRatio = 3
          ..physicalSize = const Size(360 * 3, 780 * 3);
        addTearDown(t.view.reset);
        final theme = custom('l1', 'A rather long theme name here', mode);
        await pumpApp(
          t,
          tallPhone: false,
          initial: AppearanceSettings(
            language: lang,
            mode: AppearanceMode.system,
            customThemes: [theme],
            customThemeId: 'l1',
          ),
        );
        await openAppearance(t);
        expect(t.takeException(), isNull, reason: 'row overflows');
        await tapKey(t, 'appearance-mode');
        expect(t.takeException(), isNull, reason: 'card overflows');
        for (final k in ['card', 'note', 'system', 'light', 'dark']) {
          final r = t.getRect(byKey('appearance-mode-$k'));
          expect(r.left, greaterThanOrEqualTo(0), reason: k);
          expect(r.right, lessThanOrEqualTo(360.5), reason: k);
        }
      });
    }
  }

  testWidgets('360 wide, built-in theme, both languages: no overflow', (
    t,
  ) async {
    t.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(360 * 3, 780 * 3);
    addTearDown(t.view.reset);
    for (final lang in [AppLanguage.en, AppLanguage.tr]) {
      await pumpApp(
        t,
        tallPhone: false,
        initial: AppearanceSettings(language: lang),
      );
      await openCard(t);
      expect(t.takeException(), isNull, reason: lang.name);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('SisSettingsRow: a long value is capped at half the width '
      'with an ellipsis; the title is not squeezed', (t) async {
    t.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 780);
    addTearDown(t.view.reset);
    const title = 'Light or dark';
    const value = 'A very very long value that cannot ever fit in one line';
    await t.pumpWidget(
      MaterialApp(
        theme: sisTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              SisSettingsRow(
                key: const ValueKey('row'),
                icon: Icons.contrast,
                title: title,
                value: value,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(t.takeException(), isNull);
    final row = t.getRect(byKey('row'));
    final v = t.renderObject<RenderParagraph>(find.text(value));
    expect(v.size.width, lessThanOrEqualTo(row.width / 2 + 0.5));
    expect(v.didExceedMaxLines, isTrue, reason: 'one line, cut');
    expect(t.widget<Text>(find.text(value)).overflow, TextOverflow.ellipsis);

    final ti = t.renderObject<RenderParagraph>(find.text(title));
    expect(ti.didExceedMaxLines, isFalse, reason: 'title not cut');
    // The title takes all the room the value leaves; it is not squeezed
    // further than the value's half.
    expect(
      t.getRect(find.text(title)).right,
      greaterThanOrEqualTo(t.getRect(find.text(value)).left - 16),
    );
  });
}

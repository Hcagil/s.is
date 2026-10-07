import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';
import 'package:sis/main.dart' as entry;

// Helpers
BuildContext appContext(WidgetTester t) =>
    t.element(find.byType(Navigator).first);

Future<void> firstFrameAfterStart(
  WidgetTester t,
  AppearanceSettings saved,
) async {
  SharedPreferences.setMockInitialValues({});
  await const SharedPrefsAppearanceStore().save(saved);
  await t.pumpWidget(const SizedBox());
  LicenseRegistry.reset();
  addTearDown(LicenseRegistry.reset);
  await entry.main();
  await t.pump();
}

void main() {
  testWidgets('a saved custom theme and wallpaper paint on the first frame', (
    WidgetTester t,
  ) async {
    const night = CustomTheme(
      id: 'n1',
      name: 'Night',
      mode: CustomThemeMode.dark,
      accent: 0xFF2E7D32,
      mine: 0xFF1B5E20,
      theirs: 0xFF263238,
    );
    const saved = AppearanceSettings(
      themeId: AppThemeId.ocean,
      customThemes: [night],
      customThemeId: 'n1',
      wallpaper: Wallpaper(
        kind: WallpaperKind.gradient,
        colours: [0xFF101010, 0xFF202020],
        dim: 0.5,
        blur: 4,
      ),
    );
    await firstFrameAfterStart(t, saved);

    final theme = Theme.of(appContext(t));
    expect(theme.brightness, Brightness.dark);
    expect(
      theme.colorScheme.primary,
      sisBrandForCustom(night, Brightness.dark).brand,
    );

    final provider = ProviderScope.containerOf(t.element(find.byType(SisApp)))
        .read(appearanceProvider);
    expect(provider, equals(saved));

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a light custom theme on a dark phone', (WidgetTester t) async {
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);

    const day = CustomTheme(
      id: 'd1',
      name: 'Day',
      mode: CustomThemeMode.light,
      accent: 0xFFE65100,
      mine: 0xFFFFCC80,
      theirs: 0xFFFFFFFF,
    );
    const saved = AppearanceSettings(
      themeId: AppThemeId.ocean,
      customThemes: [day],
      customThemeId: 'd1',
    );
    await firstFrameAfterStart(t, saved);

    final theme = Theme.of(appContext(t));
    expect(theme.brightness, Brightness.light);
    expect(
      theme.colorScheme.primary,
      sisBrandForCustom(day, Brightness.light).brand,
    );

    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a saved custom theme with a chat colour paints it on the first frame',
    (WidgetTester t) async {
      const sea = CustomTheme(
        id: 's1',
        name: 'Sea',
        mode: CustomThemeMode.light,
        accent: 0xFF38B6FF,
        mine: 0xFFFFFFFF,
        theirs: 0xFFFFFFFF,
        background: 0xFF102A43,
      );
      const saved = AppearanceSettings(
        themeId: AppThemeId.ocean,
        customThemes: [sea],
        customThemeId: 's1',
      );
      await firstFrameAfterStart(t, saved);
      final theme = Theme.of(appContext(t));
      expect(theme.brightness, Brightness.light);
      expect(
        theme.colorScheme.primary,
        sisBrandForCustom(sea, Brightness.light).brand,
      );
      expect(
        theme.extension<SisBrand>()!.chatBackground,
        const Color(0xFF102A43),
      );
      final provider = ProviderScope.containerOf(t.element(find.byType(SisApp)))
          .read(appearanceProvider);
      expect(provider, equals(saved));
      expect(
        provider.effectiveWallpaper(dark: false).kind,
        WallpaperKind.colour,
      );
      expect(provider.effectiveWallpaper(dark: false).colours, [0xFF102A43]);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a stored id with no theme falls back to the built-in', (
    WidgetTester t,
  ) async {
    const saved = AppearanceSettings(
      themeId: AppThemeId.ocean,
      customThemeId: 'gone',
    );
    await firstFrameAfterStart(t, saved);

    final theme = Theme.of(appContext(t));
    expect(theme.brightness, Brightness.light);
    expect(
      theme.colorScheme.primary,
      sisBrandFor(AppThemeId.ocean, Brightness.light).brand,
    );

    await t.pumpWidget(const SizedBox());
  });
}

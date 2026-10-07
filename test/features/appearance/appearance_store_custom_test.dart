import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';

void main() {
  const customThemesKey = 'sis.appearance.custom_themes';
  const customThemeIdKey = 'sis.appearance.custom_theme_id';
  const wallpaperKey = 'sis.appearance.wallpaper';

  // Helper custom themes
  final theme1 = CustomTheme(
    id: 'theme1',
    name: 'Theme 1',
    mode: CustomThemeMode.automatic,
    accent: 0xFF123456,
    mine: 0xFF654321,
    theirs: 0xFFabcdef,
  );

  final theme2 = CustomTheme(
    id: 'theme2',
    name: 'Theme 2',
    mode: CustomThemeMode.light,
    accent: 0xFF112233,
    mine: 0xFF334455,
    theirs: 0xFF556677,
  );

  // Helper wallpapers
  final wallpaperPicture = Wallpaper(
    kind: WallpaperKind.picture,
    picturePath: '/data/w.jpg',
    dim: 0.5,
    blur: 4,
  );

  final wallpaperGradient = Wallpaper(
    kind: WallpaperKind.gradient,
    colours: [0xFF000000, 0xFFFFFFFF],
    dim: 0.2,
    blur: 1,
  );

  final wallpaperColour = Wallpaper(
    kind: WallpaperKind.colour,
    colours: [0xFF123456],
    dim: 0.1,
    blur: 0,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    '1. round trip with two custom themes, picture wallpaper, and forest theme',
    () async {
      final settings = AppearanceSettings(
        themeId: AppThemeId.forest,
        customThemes: [theme1, theme2],
        customThemeId: theme2.id,
        wallpaper: wallpaperPicture,
      );

      final store = SharedPrefsAppearanceStore();
      await store.save(settings);

      final loaded = await store.load();
      expect(loaded, equals(settings));

      final prefs = await SharedPreferences.getInstance();
      final customThemesStr = prefs.getString(customThemesKey);
      final wallpaperStr = prefs.getString(wallpaperKey);
      final storedThemeId = prefs.getString(customThemeIdKey);

      expect(storedThemeId, equals(theme2.id));
      expect(customThemesStr, isNotNull);
      expect(() => jsonDecode(customThemesStr!), returnsNormally);
      expect(wallpaperStr, isNotNull);
      expect(() => jsonDecode(wallpaperStr!), returnsNormally);
    },
  );

  test('2. round trip for gradient and colour wallpapers', () async {
    final settingsGradient = AppearanceSettings(wallpaper: wallpaperGradient);
    final settingsColour = AppearanceSettings(wallpaper: wallpaperColour);

    final store = SharedPrefsAppearanceStore();

    await store.save(settingsGradient);
    final loadedGradient = await store.load();
    expect(loadedGradient.wallpaper, equals(wallpaperGradient));

    await store.save(settingsColour);
    final loadedColour = await store.load();
    expect(loadedColour.wallpaper, equals(wallpaperColour));
  });

  test('3. customThemeId null after having been set', () async {
    final store = SharedPrefsAppearanceStore();

    // First save with an id
    await store.save(AppearanceSettings(customThemeId: theme1.id));

    // Then save with null id
    await store.save(AppearanceSettings(customThemeId: null));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(customThemeIdKey), isFalse);

    final loaded = await store.load();
    expect(loaded.customThemeId, isNull);
  });

  test('4. corrupt custom_themes values', () async {
    final corruptValues = ['not json', '{"a":1}', '[1,2]', '[{"id":3}]', ''];

    for (final v in corruptValues) {
      SharedPreferences.setMockInitialValues({
        customThemesKey: v,
        'sis.appearance.theme': 'ocean',
      });

      final store = SharedPrefsAppearanceStore();
      await expectLater(store.load(), completes);

      final loaded = await store.load();
      expect(loaded.customThemes, isEmpty);
      expect(loaded.themeId, equals(AppThemeId.ocean));
    }
  });

  test('5. list with one valid theme and one garbage element', () async {
    final validJson = jsonEncode([theme1.toJson(), 7]);

    SharedPreferences.setMockInitialValues({customThemesKey: validJson});

    final store = SharedPrefsAppearanceStore();
    await expectLater(store.load(), completes);

    final loaded = await store.load();
    expect(loaded.customThemes.every((t) => t == theme1), isTrue);
  });

  test('6. corrupt wallpaper values', () async {
    final corruptValues = ['nope', '[]', '{"kind":"spaceship"}', '42', ''];

    for (final v in corruptValues) {
      SharedPreferences.setMockInitialValues({wallpaperKey: v});

      final store = SharedPrefsAppearanceStore();
      await expectLater(store.load(), completes);

      final loaded = await store.load();
      expect(loaded.wallpaper, equals(Wallpaper.none));
    }
  });

  test('7. wrong prefs TYPES', () async {
    SharedPreferences.setMockInitialValues({
      customThemesKey: 5,
      wallpaperKey: true,
      customThemeIdKey: 9,
    });

    final store = SharedPrefsAppearanceStore();
    await expectLater(store.load(), completes);

    final loaded = await store.load();
    expect(loaded.customThemes, isEmpty);
    expect(loaded.wallpaper, equals(Wallpaper.none));
    expect(loaded.customThemeId, isNull);
  });

  test('8. custom_theme_id stored but no matching theme', () async {
    SharedPreferences.setMockInitialValues({
      customThemeIdKey: 'nonexistent',
      customThemesKey: jsonEncode([theme1.toJson()]),
    });

    final store = SharedPrefsAppearanceStore();
    await expectLater(store.load(), completes);

    final loaded = await store.load();
    expect(loaded.activeCustomTheme, isNull);
    expect(loaded.customThemes, contains(theme1));
    expect(
      loaded.customThemes.where((t) => t.id == 'nonexistent').isEmpty,
      isTrue,
    );
  });
}

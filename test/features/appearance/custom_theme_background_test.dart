import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';

void main() {
  const base = CustomTheme(
    id: 't1',
    name: 'Sea',
    mode: CustomThemeMode.dark,
    accent: 0xFF38B6FF,
    mine: 0xFFFFFFFF,
    theirs: 0xFF263238,
  );
  final withBg = base.copyWith(background: 0xFF102A43);

  group('CustomTheme.background', () {
    test('round trip with background', () {
      final json = withBg.toJson();
      final theme = CustomTheme.tryFromJson(json);
      expect(theme, equals(withBg));
      expect(theme?.background, equals(0xFF102A43));
    });

    test('round trip without background', () {
      final json = base.toJson();
      final theme = CustomTheme.tryFromJson(json);
      expect(theme, equals(base));
      expect(theme?.background, isNull);
    });

    test('toJson omits key when null', () {
      expect(base.toJson().containsKey('background'), isFalse);
      expect(withBg.toJson()['background'], equals(0xFF102A43));
    });

    test('legacy JSON loads non-null with background null', () {
      final legacy = {
        'id': 't1',
        'name': 'Sea',
        'mode': 'dark',
        'accent': 0xFF38B6FF,
        'mine': 0xFFFFFFFF,
        'theirs': 0xFF263238,
      };
      final theme = CustomTheme.tryFromJson(legacy);
      expect(theme, isNotNull);
      expect(theme?.background, isNull);
    });

    test('non-int background loads non-null with background null', () {
      final values = ['blue', 1.5, true, {}];
      for (final val in values) {
        final json = {
          'id': 't1',
          'name': 'Sea',
          'mode': 'dark',
          'accent': 0xFF38B6FF,
          'mine': 0xFFFFFFFF,
          'theirs': 0xFF263238,
          'background': val,
        };
        final theme = CustomTheme.tryFromJson(json);
        expect(theme, isNotNull);
        expect(theme?.background, isNull);
      }
    });

    test('== and hashCode', () {
      expect(withBg, isNot(equals(base)));
      expect(withBg.hashCode, isNot(base.hashCode));
      expect(
        base.copyWith(background: 1).hashCode,
        isNot(base.copyWith(background: 2).hashCode),
      );
      expect(withBg, equals(base.copyWith(background: 0xFF102A43)));
      expect(
        withBg.hashCode,
        equals(base.copyWith(background: 0xFF102A43).hashCode),
      );
      expect(
        base.copyWith(background: 1),
        isNot(equals(base.copyWith(background: 2))),
      );
    });

    test('copyWith keeps background when not passed', () {
      expect(withBg.copyWith(name: 'X').background, equals(0xFF102A43));
    });
  });

  group('effectiveWallpaper', () {
    final gradientWallpaper = Wallpaper(
      kind: WallpaperKind.gradient,
      colours: [0xFF101010, 0xFF202020],
      dim: 0.0,
      blur: 0.0,
    );

    test('own wallpaper wins', () {
      final settings = AppearanceSettings(
        customThemes: [withBg],
        customThemeId: 't1',
        wallpaper: gradientWallpaper,
      );
      expect(
        settings.effectiveWallpaper(dark: false),
        equals(gradientWallpaper),
      );
      expect(
        settings.effectiveWallpaper(dark: true),
        equals(gradientWallpaper),
      );
    });

    test('custom background gives a colour wallpaper', () {
      final settings = AppearanceSettings(
        customThemes: [withBg],
        customThemeId: 't1',
        wallpaper: Wallpaper.none,
      );
      final dark = settings.effectiveWallpaper(dark: true);
      final light = settings.effectiveWallpaper(dark: false);
      expect(dark.kind, equals(WallpaperKind.colour));
      expect(dark.colours, equals([0xFF102A43]));
      expect(light.kind, equals(WallpaperKind.colour));
      expect(light.colours, equals([0xFF102A43]));
    });

    test('active custom theme without background', () {
      final settings = AppearanceSettings(
        customThemes: [base],
        customThemeId: 't1',
        wallpaper: Wallpaper.none,
      );
      expect(settings.effectiveWallpaper(dark: true), equals(Wallpaper.none));
      expect(settings.effectiveWallpaper(dark: false), equals(Wallpaper.none));
    });
  });

  group('sisBrandForCustom', () {
    test('chatBackground for withBg light and dark', () {
      final color = Color(0xFF102A43);
      final brandLight = sisBrandForCustom(
        withBg,
        Brightness.light,
        wallpaperSet: false,
      );
      final brandDark = sisBrandForCustom(
        withBg,
        Brightness.dark,
        wallpaperSet: false,
      );
      expect(brandLight.chatBackground, equals(color));
      expect(brandDark.chatBackground, equals(color));
    });

    test('chatBackground null when wallpaperSet', () {
      final brand = sisBrandForCustom(
        withBg,
        Brightness.light,
        wallpaperSet: true,
      );
      expect(brand.chatBackground, isNull);
    });

    test('chatBackground null for base', () {
      final brand = sisBrandForCustom(
        base,
        Brightness.light,
        wallpaperSet: false,
      );
      expect(brand.chatBackground, isNull);
    });

    test('mineGradient is flat', () {
      final brandBase = sisBrandForCustom(base, Brightness.light);
      final colorsBase = brandBase.mineGradient.colors;
      expect(colorsBase, isNotEmpty);
      expect(colorsBase.every((c) => c == Color(0xFFFFFFFF)), isTrue);
      expect(brandBase.mine, equals(Color(0xFFFFFFFF)));

      final themeWithMine = base.copyWith(mine: 0xFFE8D9FF);
      final brandMine = sisBrandForCustom(themeWithMine, Brightness.light);
      final colorsMine = brandMine.mineGradient.colors;
      expect(colorsMine, isNotEmpty);
      expect(colorsMine.every((c) => c == Color(0xFFE8D9FF)), isTrue);
      expect(brandMine.mine, equals(Color(0xFFE8D9FF)));
    });
  });
}

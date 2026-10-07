import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';

void main() {
  group('CustomTheme', () {
    final modes = CustomThemeMode.values;
    final sampleTheme = CustomTheme(
      id: 'sample',
      name: 'Sample',
      mode: CustomThemeMode.automatic,
      accent: 0xFF123456,
      mine: 0x80FFFFFF,
      theirs: 0xFFABCDEF,
    );

    test('toJson -> tryFromJson round trip preserves values', () {
      for (final mode in modes) {
        final theme = CustomTheme(
          id: 'id_$mode',
          name: 'name_$mode',
          mode: mode,
          accent: 0xFF123456,
          mine: 0x80FFFFFF,
          theirs: 0xFFABCDEF,
        );
        final json = theme.toJson();
        final roundTrip = CustomTheme.tryFromJson(json);
        expect(roundTrip, isNotNull);
        expect(roundTrip, equals(theme));
      }
    });

    test('tryFromJson returns null for invalid inputs', () {
      final invalidInputs = <Object?>[
        null,
        'text',
        42,
        <String, dynamic>{},
        [1, 2, 3],
      ];
      for (final input in invalidInputs) {
        expect(CustomTheme.tryFromJson(input), isNull);
      }

      // Missing required keys
      final json = sampleTheme.toJson();
      final copyMissingId = Map.of(json)..remove('id');
      expect(CustomTheme.tryFromJson(copyMissingId), isNull);

      final copyMissingName = Map.of(json)..remove('name');
      expect(CustomTheme.tryFromJson(copyMissingName), isNull);

      // Wrong type for each key
      for (final key in json.keys) {
        final copy = Map.of(json)..[key] = <int>[1, 2, 3];
        expect(CustomTheme.tryFromJson(copy), isNull);
      }
    });
  });

  group('Wallpaper', () {
    final colourWallpaper = Wallpaper(
      kind: WallpaperKind.colour,
      colours: [0xFF112233],
    );
    final gradientWallpaper = Wallpaper(
      kind: WallpaperKind.gradient,
      colours: [0xFF112233, 0xFF445566],
    );
    final pictureWallpaper = Wallpaper(
      kind: WallpaperKind.picture,
      picturePath: '/x/y.jpg',
      dim: 0.5,
      blur: 6.0,
    );
    final noneWallpaper = Wallpaper.none;

    test('toJson -> tryFromJson round trip preserves values', () {
      for (final w in [
        colourWallpaper,
        gradientWallpaper,
        pictureWallpaper,
        noneWallpaper,
      ]) {
        final json = w.toJson();
        final roundTrip = Wallpaper.tryFromJson(json);
        expect(roundTrip, isNotNull);
        expect(roundTrip, equals(w));
      }
    });

    test('tryFromJson returns Wallpaper.none for invalid inputs', () {
      final invalidInputs = <Object?>[
        null,
        'text',
        42,
        <String, dynamic>{},
        [1, 2, 3],
      ];
      for (final input in invalidInputs) {
        expect(Wallpaper.tryFromJson(input), equals(Wallpaper.none));
      }
    });

    test('clamping of dim and blur', () {
      final json = pictureWallpaper.toJson();
      expect(json.containsKey('dim'), isTrue);
      expect(json.containsKey('blur'), isTrue);

      // dim clamping
      final dimHigh = Map.of(json)..['dim'] = 2.0;
      final dimLow = Map.of(json)..['dim'] = -1.0;
      expect(Wallpaper.tryFromJson(dimHigh).dim, closeTo(0.8, 1e-6));
      expect(Wallpaper.tryFromJson(dimLow).dim, closeTo(0.0, 1e-6));

      // blur clamping
      final blurHigh = Map.of(json)..['blur'] = 99.0;
      final blurLow = Map.of(json)..['blur'] = -5.0;
      expect(Wallpaper.tryFromJson(blurHigh).blur, closeTo(12.0, 1e-6));
      expect(Wallpaper.tryFromJson(blurLow).blur, closeTo(0.0, 1e-6));
    });
  });

  group('builtInWallpaper', () {
    test('returns correct wallpaper for each AppThemeId', () {
      expect(
        builtInWallpaper(AppThemeId.violet).kind,
        equals(WallpaperKind.none),
      );

      final gradientMap = {
        AppThemeId.ocean: [0xFF0B2A45, 0xFF0A1626],
        AppThemeId.forest: [0xFF0F2E22, 0xFF0A1A14],
        AppThemeId.sunset: [0xFF3A1630, 0xFF1C0C1E],
        AppThemeId.graphite: [0xFF25282E, 0xFF15171B],
        AppThemeId.rose: [0xFF38142A, 0xFF1A0A14],
      };

      for (final entry in gradientMap.entries) {
        final wp = builtInWallpaper(entry.key);
        expect(wp.kind, equals(WallpaperKind.gradient));
        expect(wp.colours, equals(entry.value));
      }
    });
  });

  group('AppearanceSettings.effectiveWallpaper', () {
    final customTheme = CustomTheme(
      id: 't1',
      name: 'Custom',
      mode: CustomThemeMode.automatic,
      accent: 0xFF123456,
      mine: 0x80FFFFFF,
      theirs: 0xFFABCDEF,
    );
    final colourWallpaper = Wallpaper(
      kind: WallpaperKind.colour,
      colours: [0xFF112233],
    );

    test(
      'member wallpaper non-none wins regardless of theme or custom theme',
      () {
        for (final dark in [true, false]) {
          final settings = AppearanceSettings(
            themeId: AppThemeId.ocean,
            wallpaper: colourWallpaper,
            customThemes: [customTheme],
            customThemeId: customTheme.id,
          );
          expect(
            settings.effectiveWallpaper(dark: dark),
            equals(colourWallpaper),
          );
        }
      },
    );

    test('wallpaper none with active custom theme returns Wallpaper.none', () {
      for (final dark in [true, false]) {
        final settings = AppearanceSettings(
          themeId: AppThemeId.ocean,
          wallpaper: Wallpaper.none,
          customThemes: [customTheme],
          customThemeId: customTheme.id,
        );
        expect(settings.effectiveWallpaper(dark: dark), equals(Wallpaper.none));
      }
    });

    test('wallpaper none with no custom theme uses built-in or none', () {
      for (final id in AppThemeId.values) {
        for (final dark in [true, false]) {
          final settings = AppearanceSettings(
            themeId: id,
            wallpaper: Wallpaper.none,
            customThemes: const [],
            customThemeId: null,
          );
          final result = settings.effectiveWallpaper(dark: dark);
          if (dark) {
            expect(result, equals(builtInWallpaper(id)));
          } else {
            expect(result.kind, equals(WallpaperKind.none));
          }
        }
      }
    });
  });

  group('AppearanceSettings.activeCustomTheme', () {
    final customTheme = CustomTheme(
      id: 't1',
      name: 'Custom',
      mode: CustomThemeMode.automatic,
      accent: 0xFF123456,
      mine: 0x80FFFFFF,
      theirs: 0xFFABCDEF,
    );

    test('returns null when customThemeId is null', () {
      final settings = AppearanceSettings(
        themeId: AppThemeId.violet,
        customThemes: [customTheme],
        customThemeId: null,
      );
      expect(settings.activeCustomTheme, isNull);
    });

    test('returns matching theme when id is present', () {
      final settings = AppearanceSettings(
        themeId: AppThemeId.violet,
        customThemes: [customTheme],
        customThemeId: customTheme.id,
      );
      expect(settings.activeCustomTheme, equals(customTheme));
    });

    test('returns null when id not in list', () {
      final settings = AppearanceSettings(
        themeId: AppThemeId.violet,
        customThemes: [customTheme],
        customThemeId: 'nonexistent',
      );
      expect(settings.activeCustomTheme, isNull);
    });
  });
}

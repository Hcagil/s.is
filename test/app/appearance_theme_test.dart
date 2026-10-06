// The six palettes, the font switch and the text scaler, from the contract.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

const white = Color(0xFFFFFFFF);

void main() {
  group('sisTheme', () {
    for (final b in Brightness.values) {
      test('$b: system font means no family, off means Manrope', () {
        final system = sisTheme(b);
        final own = sisTheme(b, systemFont: false);
        for (final style in [
          system.textTheme.bodyMedium,
          system.textTheme.titleLarge,
        ]) {
          // No family of our own (fontFamily null): the platform default,
          // which is Roboto under test.
          expect(style?.fontFamily, 'Roboto');
        }
        for (final style in [
          own.textTheme.bodyMedium,
          own.textTheme.titleLarge,
        ]) {
          expect(style?.fontFamily, 'Manrope');
        }
      });

      for (final id in AppThemeId.values) {
        test('$b ${id.name}: carries its own brand, in $b', () {
          final theme = sisTheme(b, theme: id);
          expect(theme.brightness, b);
          final want = sisBrandFor(id, b);
          final got = theme.extension<SisBrand>()!;
          for (final (name, g, w) in [
            ('brand', got.brand, want.brand),
            ('brandDeep', got.brandDeep, want.brandDeep),
            ('background', got.background, want.background),
            ('text', got.text, want.text),
            ('theirs', got.theirs, want.theirs),
          ]) {
            expect(g, w, reason: name);
          }
          expect(theme.colorScheme.primary, want.brand);
        });
      }
    }

    test('the default theme is violet', () {
      for (final b in Brightness.values) {
        expect(
          sisTheme(b).extension<SisBrand>()!.brand,
          sisBrandFor(AppThemeId.violet, b).brand,
        );
      }
    });
  });

  group('sisBrandFor', () {
    test('six different palettes per brightness', () {
      for (final b in Brightness.values) {
        final brands = {
          for (final id in AppThemeId.values) sisBrandFor(id, b).brand,
        };
        expect(brands, hasLength(6), reason: '$b');
      }
    });

    for (final b in Brightness.values) {
      for (final id in AppThemeId.values) {
        test('${id.name} $b meets text contrast (WCAG AA 4.5:1)', () {
          final p = sisBrandFor(id, b);
          final pairs = {
            'text on background': (p.text, p.background),
            'text on surface': (p.text, p.surface),
            'text on surfaceHigh': (p.text, p.surfaceHigh),
            'text on their bubble': (p.text, p.theirs),
            'muted on background': (p.muted, p.background),
            'muted on surface': (p.muted, p.surface),
            // My bubble is the brandDeep -> brand gradient with white text;
            // the deep end carries the contrast (the light end is a highlight,
            // as on the approved violet, where white on brand is 3.9:1).
            'white on my bubble (brandDeep)': (white, p.brandDeep),
          };
          for (final e in pairs.entries) {
            final (fg, bg) = e.value;
            expect(
              contrast(fg, bg),
              greaterThanOrEqualTo(4.5),
              reason: '${e.key}: ${contrast(fg, bg).toStringAsFixed(2)}',
            );
          }
        });
      }
    }
  });

  group('sisTextScaler', () {
    test('multiplies the system scale by the factor', () {
      for (final (system, factor) in [(1.0, 1.2), (1.5, 0.88), (2.0, 1.0)]) {
        final s = sisTextScaler(TextScaler.linear(system), factor);
        expect(s.scale(10), closeTo(10 * system * factor, 1e-9));
      }
    });

    test('a factor of 1 leaves the system scale as it is', () {
      final s = sisTextScaler(const TextScaler.linear(1.3), 1.0);
      expect(s.scale(20), closeTo(26, 1e-9));
    });
  });
}

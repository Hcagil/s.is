// tests the WCAG maths
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/domain/contrast.dart';

void main() {
  group('constants', () {
    test('textMinContrast and accentMinContrast', () {
      expect(textMinContrast, equals(4.5));
      expect(accentMinContrast, equals(3.0));
    });
  });

  group('relativeLuminance', () {
    test('basic colours', () {
      expect(relativeLuminance(0xFFFFFFFF), closeTo(1.0, 0.01));
      expect(relativeLuminance(0xFF000000), closeTo(0.0, 0.01));
      expect(relativeLuminance(0xFF808080), closeTo(0.2159, 0.01));
      expect(relativeLuminance(0xFFFF0000), closeTo(0.2126, 0.01));
      expect(relativeLuminance(0xFF00FF00), closeTo(0.7152, 0.01));
      expect(relativeLuminance(0xFF0000FF), closeTo(0.0722, 0.01));
    });
  });

  group('contrastRatio', () {
    test('white vs black', () {
      expect(contrastRatio(0xFFFFFFFF, 0xFF000000), closeTo(21.0, 0.01));
    });

    test('same colour', () {
      expect(contrastRatio(0xFF123456, 0xFF123456), closeTo(1.0, 0.01));
    });

    test('symmetry', () {
      final a = 0xFF7B6BFF;
      final b = 0xFF0D0B22;
      expect(contrastRatio(a, b), closeTo(contrastRatio(b, a), 0.01));
    });

    test('mid grey against white', () {
      expect(contrastRatio(0xFF777777, 0xFFFFFFFF), closeTo(4.48, 0.01));
      expect(contrastRatio(0xFF767676, 0xFFFFFFFF), closeTo(4.54, 0.01));
    });
  });

  group('readableOn', () {
    test('preferred meets threshold', () {
      expect(readableOn(0xFFFFFFFF, preferred: 0xFF767676), equals(0xFF767676));
    });

    test('preferred below threshold, choose black', () {
      expect(readableOn(0xFFFFFFFF, preferred: 0xFF777777), equals(0xFF000000));
    });

    test('preferred white on dark background', () {
      expect(readableOn(0xFF0D0B22, preferred: 0xFFFFFFFF), equals(0xFFFFFFFF));
    });

    test('preferred white on light background', () {
      expect(readableOn(0xFFF5F4FA, preferred: 0xFFFFFFFF), equals(0xFF000000));
    });

    test('preferred black on dark background', () {
      expect(readableOn(0xFF0D0B22, preferred: 0xFF000000), equals(0xFFFFFFFF));
    });

    test('preferred red on black background', () {
      expect(readableOn(0xFF000000, preferred: 0xFFFF0000), equals(0xFFFF0000));
    });

    test('always >= 4.5 for common backgrounds', () {
      final backgrounds = [
        0xFFFFFFFF,
        0xFF000000,
        0xFF808080,
        0xFF7B6BFF,
        0xFFE8D9FF,
        0xFF1D1A42,
        0xFF38B6FF,
        0xFFF06292,
      ];
      for (final bg in backgrounds) {
        final white = readableOn(bg, preferred: 0xFFFFFFFF);
        final black = readableOn(bg, preferred: 0xFF000000);
        expect(contrastRatio(white, bg), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(black, bg), greaterThanOrEqualTo(4.5));
      }
    });
  });

  group('readableOnWhitePreferred', () {
    test('various backgrounds', () {
      expect(readableOnWhitePreferred(0xFF1D1A42), equals(0xFFFFFFFF));
      expect(readableOnWhitePreferred(0xFFFFFFFF), equals(0xFF000000));
      expect(readableOnWhitePreferred(0xFFE8D9FF), equals(0xFF000000));
    });
  });

  group('accentHardToRead', () {
    test('accent vs surface', () {
      expect(accentHardToRead(0xFF9AA3B2, 0xFFFFFFFF), equals(true));
      expect(accentHardToRead(0xFF7B6BFF, 0xFFFFFFFF), equals(false));
      expect(accentHardToRead(0xFF9AA3B2, 0xFF0D0B22), equals(false));
      expect(accentHardToRead(0xFFF06292, 0xFFFFFFFF), equals(false));
      expect(accentHardToRead(0xFFF06292, 0xFFF5F4FA), equals(true));
    });
  });
}

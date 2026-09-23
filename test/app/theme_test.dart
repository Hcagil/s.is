import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

const lightBg = Color(0xFFF5F4FA);
const lightPrimary = Color(0xFF5B4CF0);
const darkBg = Color(0xFF0D0B22);
const darkPrimary = Color(0xFF7B6BFF);

/// Pumps [child] under [theme] and hands back a context inside it.
Future<BuildContext> under(
  WidgetTester t,
  ThemeData theme,
  Widget child,
) async {
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (c) {
              ctx = c;
              return child;
            },
          ),
        ),
      ),
    ),
  );
  return ctx;
}

void main() {
  for (final (brightness, bg, primary) in [
    (Brightness.light, lightBg, lightPrimary),
    (Brightness.dark, darkBg, darkPrimary),
  ]) {
    group('$brightness', () {
      final theme = sisTheme(brightness);

      test('is $brightness throughout', () {
        expect(theme.brightness, brightness);
        expect(theme.colorScheme.brightness, brightness);
      });

      test('has the brand background and primary', () {
        expect(theme.scaffoldBackgroundColor, bg);
        expect(theme.colorScheme.primary, primary);
      });

      test('sets text in Manrope', () {
        final t = theme.textTheme;
        for (final style in [
          t.bodyMedium,
          t.bodyLarge,
          t.titleMedium,
          t.titleLarge,
          t.labelLarge,
          t.headlineSmall,
        ]) {
          expect(style?.fontFamily, 'Manrope');
        }
      });

      testWidgets('SisBrand is reachable from a context, with a 2-stop '
          'gradient and a 3-stop prism', (t) async {
        final ctx = await under(t, theme, const SizedBox());
        final brand = SisBrand.of(ctx);
        expect(identical(brand, theme.extension<SisBrand>()), isTrue);
        expect(brand.gradient, isA<LinearGradient>());
        expect(brand.gradient.colors, hasLength(2));
        expect(brand.prism.colors, hasLength(3));
        expect(brand.brand, isA<Color>());
        expect(brand.theirs, isA<Color>());
        expect(brand.background, isA<Color>());
        expect(
          brand.theirs,
          isNot(brand.background),
          reason: 'their bubbles would vanish into the page',
        );
      });

      testWidgets('a filled button has 12px rounded corners', (t) async {
        await under(
          t,
          theme,
          FilledButton(onPressed: () {}, child: const Text('Go')),
        );
        final shape = t
            .widget<Material>(
              find.descendant(
                of: find.byType(FilledButton),
                matching: find.byType(Material),
              ),
            )
            .shape;
        expect(shape, isA<RoundedRectangleBorder>());
        expect(
          (shape! as RoundedRectangleBorder).borderRadius.resolve(
            TextDirection.ltr,
          ),
          BorderRadius.circular(12),
        );
      });

      testWidgets('an input field has 8px rounded corners', (t) async {
        await under(t, theme, const TextField());
        final d = t.widget<InputDecorator>(find.byType(InputDecorator));
        final borders = [
          d.decoration.border,
          d.decoration.enabledBorder,
          d.decoration.focusedBorder,
        ].whereType<InputBorder>().toList();
        expect(borders, isNotEmpty, reason: 'the theme sets no field border');
        for (final b in borders) {
          expect(b, isA<OutlineInputBorder>());
          expect(
            (b as OutlineInputBorder).borderRadius,
            BorderRadius.circular(8),
          );
        }
      });
    });
  }
}

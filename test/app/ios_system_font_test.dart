import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

void main() {
  const brightnesses = [Brightness.light, Brightness.dark];
  const systemFontValues = [true, false];

  for (final brightness in brightnesses) {
    for (final systemFont in systemFontValues) {
      final testName =
          'sisTheme with brightness=$brightness, systemFont=$systemFont';
      testWidgets(testName, (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: sisTheme(brightness, systemFont: systemFont),
              home: Scaffold(
                appBar: AppBar(title: const Text('Title')),
                body: Column(
                  children: [
                    FilledButton(
                      onPressed: () {},
                      child: const Text('Go'),
                    ),
                    const Text('Plain'),
                  ],
                ),
              ),
            ),
          );

          final BuildContext ctx = tester.element(find.text('Plain'));

          // Helper to check font family with a label
          void checkFontFamily(String? family, String what) {
            if (systemFont) {
              expect(family, isNotNull, reason: what);
              expect(family!.startsWith('CupertinoSystem'), isTrue,
                  reason: '$what=$family');
            } else {
              expect(family, equals('Manrope'), reason: what);
            }
          }

          // Check all non-null text styles in the theme
          final textTheme = Theme.of(ctx).textTheme;
          final styles = [
            textTheme.displayLarge,
            textTheme.displayMedium,
            textTheme.displaySmall,
            textTheme.headlineLarge,
            textTheme.headlineMedium,
            textTheme.headlineSmall,
            textTheme.titleLarge,
            textTheme.titleMedium,
            textTheme.titleSmall,
            textTheme.bodyLarge,
            textTheme.bodyMedium,
            textTheme.bodySmall,
            textTheme.labelLarge,
            textTheme.labelMedium,
            textTheme.labelSmall,
          ];
          for (var i = 0; i < styles.length; i++) {
            final style = styles[i];
            if (style != null) {
              checkFontFamily(style.fontFamily, 'textTheme slot $i');
            }
          }

          // Check DefaultTextStyle for 'Plain'
          final plainStyle = DefaultTextStyle.of(ctx).style;
          checkFontFamily(plainStyle.fontFamily, 'DefaultTextStyle');

          // Helper to get rendered font family from RichText
          String? renderedFamily(String text) {
            final rt = tester.widget<RichText>(find.byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText() == text));
            return rt.text.style?.fontFamily;
          }

          // Check AppBar title style
          checkFontFamily(renderedFamily('Title'), 'AppBar title');

          // Check FilledButton text style
          checkFontFamily(renderedFamily('Go'), 'FilledButton label');

          // Check Plain text style
          checkFontFamily(renderedFamily('Plain'), 'Plain text');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}

// t_516326574c: a FilledButton's label uses the chosen app font (Manrope when
// the system font is switched off) and stays on the phone's font otherwise.
// Written from the contract; the button is drawn in the app's own theme.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

Future<String?> labelFamily(WidgetTester t, ThemeData theme) async {
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Column(
          children: [
            FilledButton(onPressed: () {}, child: const Text('Send')),
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        ),
      ),
    ),
  );
  final send = t.renderObject<RenderParagraph>(find.text('Send'));
  final add = t.renderObject<RenderParagraph>(find.text('Add'));
  expect(add.text.style?.fontFamily, send.text.style?.fontFamily);
  return send.text.style?.fontFamily;
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('$b, app font chosen: the label is Manrope', (t) async {
      final theme = sisTheme(b, systemFont: false);
      expect(
        theme.filledButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
        'Manrope',
      );
      expect(await labelFamily(t, theme), 'Manrope');
    });

    testWidgets('$b, system font: no family on the label (the phone\'s own '
        'font, as before the change)', (t) async {
      expect(await labelFamily(t, sisTheme(b)), isNull);
    });
  }
}

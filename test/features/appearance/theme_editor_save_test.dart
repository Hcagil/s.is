import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';

import 'custom_themes_page_test.dart'
    show pumpApp, look, byKey, tapKey, reveal, openAppearance, hasCheck;

/// Helper to open the editor for a new theme with the given [name].
Future<void> openEditor(WidgetTester t, String name) async {
  await openAppearance(t);
  await tapKey(t, 'appearance-new-theme');
  await t.enterText(byKey('new-theme-field'), name);
  await tapKey(t, 'new-theme-create');
}

/// Helper to pick a swatch in a given [tab].
Future<void> pick(WidgetTester t, String tab, String swatch) async {
  await tapKey(t, tab);
  await tapKey(t, swatch);
}

/// Helper to change the mode by tapping the segment with [label].
Future<void> mode(WidgetTester t, String label) async {
  await t.tap(
    find.descendant(of: byKey('editor-mode'), matching: find.text(label)),
  );
  await t.pumpAndSettle();
}

/// Returns the set of selected modes in the editor.
Set<CustomThemeMode> modeOf(WidgetTester t) =>
    t.widget<SegmentedButton<CustomThemeMode>>(byKey('editor-mode')).selected;

/// Checks if a widget with [key] paints the given [argb] color.
bool paints(WidgetTester t, String key, int argb) {
  final c = Color(argb);
  final widgets = find
      .descendant(of: byKey(key), matching: find.byWidgetPredicate((_) => true))
      .evaluate();
  for (final w in widgets) {
    final widget = w.widget;
    final decoration = switch (widget) {
      Container(:final decoration) => decoration,
      DecoratedBox(:final decoration) => decoration,
      Ink(:final decoration) => decoration,
      _ => null,
    };
    if (decoration is BoxDecoration) {
      if (decoration.color == c ||
          (decoration.gradient?.colors.contains(c) ?? false)) {
        return true;
      }
    } else if (decoration is ShapeDecoration) {
      if (decoration.color == c ||
          (decoration.gradient?.colors.contains(c) ?? false)) {
        return true;
      }
    } else if (widget is ColoredBox && widget.color == c) {
      return true;
    } else if (widget is Material && widget.color == c) {
      return true;
    }
  }
  return false;
}

/// Returns the created theme with the given [name].
CustomTheme created(WidgetTester t, String name) =>
    look(t).customThemes.singleWhere((x) => x.name == name);

void main() {
  group('live preview', () {
    testWidgets('a mine swatch repaints the preview after one pump', (
      WidgetTester t,
    ) async {
      await pumpApp(t);
      await openEditor(t, 'Sea');
      await tapKey(t, 'editor-tab-mine');
      expect(paints(t, 'editor-preview-mine', 0xFFFFFFFF), isFalse);
      await t.tap(byKey('swatch-mine-FFFFFF'));
      await t.pump();
      expect(paints(t, 'editor-preview-mine', 0xFFFFFFFF), isTrue);
    });

    testWidgets('a background swatch repaints the preview after one pump', (
      WidgetTester t,
    ) async {
      await pumpApp(t);
      await openEditor(t, 'Sea');
      await tapKey(t, 'editor-tab-background');
      expect(paints(t, 'editor-preview', 0xFF102A43), isFalse);
      await t.tap(byKey('swatch-background-102A43'));
      await t.pump();
      expect(paints(t, 'editor-preview', 0xFF102A43), isTrue);
    });
  });

  group('contrast warning', () {
    testWidgets('shown below 3:1, hidden otherwise, accent tab only', (
      WidgetTester t,
    ) async {
      await pumpApp(t);
      await openEditor(t, 'Sea');
      expect(byKey('editor-contrast-warning'), findsNothing);
      await t.tap(byKey('swatch-accent-9AA3B2'));
      await t.pump();
      expect(
        find.text('Accent may be hard to read. Consider a darker shade.'),
        findsOneWidget,
      );
      expect(byKey('editor-contrast-warning'), findsOneWidget);
      await tapKey(t, 'editor-tab-background');
      expect(byKey('editor-contrast-warning'), findsNothing);
      await t.tap(byKey('swatch-background-0D0B22'));
      await tapKey(t, 'editor-tab-accent');
      expect(byKey('editor-contrast-warning'), findsNothing);
    });

    testWidgets('shown in Turkish', (WidgetTester t) async {
      await pumpApp(
        t,
        initial: const AppearanceSettings(language: AppLanguage.tr),
      );
      await openEditor(t, 'Sea');
      await t.tap(byKey('swatch-accent-9AA3B2'));
      await t.pump();
      expect(
        find.text('Bu vurgu rengi zor okunabilir. Daha koyu bir ton seçin.'),
        findsOneWidget,
      );
    });
  });

  group('save', () {
    testWidgets('save creates and selects the theme', (WidgetTester t) async {
      await pumpApp(t);
      await openEditor(t, 'Sea');
      await pick(t, 'editor-tab-accent', 'swatch-accent-38B6FF');
      await pick(t, 'editor-tab-background', 'swatch-background-102A43');
      await pick(t, 'editor-tab-mine', 'swatch-mine-FFFFFF');
      await mode(t, 'Dark');
      await tapKey(t, 'editor-save');
      expect(byKey('editor-preview'), findsNothing);
      expect(byKey('appearance-new-theme'), findsOneWidget);
      final s = created(t, 'Sea');
      expect(s.accent, 0xFF38B6FF);
      expect(s.background, 0xFF102A43);
      expect(s.mine, 0xFFFFFFFF);
      expect(s.mode, CustomThemeMode.dark);
      expect(look(t).customThemeId, s.id);
      await reveal(t, byKey('custom-theme-${s.id}'));
      expect(hasCheck(byKey('custom-theme-${s.id}')), isTrue);
    });

    testWidgets('the top save button saves too', (WidgetTester t) async {
      await pumpApp(t);
      await openEditor(t, 'Top');
      await pick(t, 'editor-tab-accent', 'swatch-accent-4CC38A');
      await tapKey(t, 'editor-save-top');
      final s = created(t, 'Top');
      expect(s.accent, 0xFF4CC38A);
      expect(look(t).customThemeId, s.id);
    });

    testWidgets('the name is trimmed', (WidgetTester t) async {
      await pumpApp(t);
      await openEditor(t, '  Sea  ');
      await tapKey(t, 'editor-save');
      final s = created(t, 'Sea');
      expect(s.name, 'Sea');
    });
  });

  group('cancel', () {
    testWidgets('cancel changes nothing', (WidgetTester t) async {
      await pumpApp(t);
      await openAppearance(t);
      final before = look(t);
      await tapKey(t, 'appearance-new-theme');
      await t.enterText(byKey('new-theme-field'), 'Sea');
      await tapKey(t, 'new-theme-create');
      await pick(t, 'editor-tab-accent', 'swatch-accent-38B6FF');
      await mode(t, 'Dark');
      await tapKey(t, 'editor-cancel');
      expect(byKey('editor-preview'), findsNothing);
      expect(look(t), equals(before));
    });

    testWidgets('back changes nothing', (WidgetTester t) async {
      await pumpApp(t);
      await openAppearance(t);
      final before = look(t);
      await tapKey(t, 'appearance-new-theme');
      await t.enterText(byKey('new-theme-field'), 'Sea');
      await tapKey(t, 'new-theme-create');
      await pick(t, 'editor-tab-accent', 'swatch-accent-38B6FF');
      await mode(t, 'Dark');
      await t.pageBack();
      await t.pumpAndSettle();
      expect(byKey('editor-preview'), findsNothing);
      expect(look(t), equals(before));
    });
  });

  group('reset', () {
    testWidgets('reset goes back to the defaults', (WidgetTester t) async {
      await pumpApp(t);
      await openEditor(t, 'A');
      await tapKey(t, 'editor-save');
      final d = created(t, 'A');

      // Start editing a new theme
      await tapKey(t, 'appearance-new-theme');
      await t.enterText(byKey('new-theme-field'), 'B');
      await tapKey(t, 'new-theme-create');
      await pick(t, 'editor-tab-accent', 'swatch-accent-38B6FF');
      await pick(t, 'editor-tab-background', 'swatch-background-102A43');
      await pick(t, 'editor-tab-mine', 'swatch-mine-FFFFFF');
      await mode(t, 'Dark');

      // Reset to defaults
      await tapKey(t, 'editor-reset');
      expect(modeOf(t), {CustomThemeMode.light});

      // Save the reset theme
      await tapKey(t, 'editor-save');
      final b = created(t, 'B');
      expect(b.accent, 0xFF7B6BFF);
      expect(b.background, isNull);
      expect(b.mode, CustomThemeMode.light);
      expect(b.mine, d.mine);
      expect(b.theirs, d.theirs);

      // Verify defaults match the original theme
      expect(d.accent, 0xFF7B6BFF);
      expect(d.background, isNull);
      expect(d.mode, CustomThemeMode.light);
    });
  });
}

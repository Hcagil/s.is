import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/domain/contrast.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';

import 'custom_themes_page_test.dart'
    show pumpApp, look, byKey, tapKey, openAppearance;

/// Opens the editor for a new theme with the given [name].
Future<void> openEditor(WidgetTester t, String name) async {
  await tapKey(t, 'appearance-new-theme');
  await t.enterText(byKey('new-theme-field'), name);
  await tapKey(t, 'new-theme-create');
}

/// Returns the ARGB values of all swatches in the given [group].
/// The values are deduplicated and returned in the order they appear.
List<int> swatches(WidgetTester t, String group) {
  final finder = find.byWidgetPredicate((w) {
    if (w.key is! ValueKey<String>) return false;
    final key = w.key as ValueKey<String>;
    return key.value.startsWith('swatch-$group-');
  });
  final colors = <int>[];
  final seen = <int>{};
  for (final widget in t.widgetList(finder)) {
    final key = widget.key as ValueKey<String>;
    final hex = key.value.substring('swatch-$group-'.length);
    final intVal = 0xFF000000 | int.parse(hex, radix: 16);
    if (seen.add(intVal)) colors.add(intVal);
  }
  return colors;
}

void main() {
  testWidgets('every swatch reads at 4.5:1 in Light and Dark', (
    WidgetTester t,
  ) async {
    await pumpApp(t);
    await openAppearance(t);

    final List<Map<String, dynamic>> configs = [
      {
        'label': 'Light',
        'brightness': Brightness.light,
        'mode': CustomThemeMode.light,
      },
      {
        'label': 'Dark',
        'brightness': Brightness.dark,
        'mode': CustomThemeMode.dark,
      },
    ];

    for (final cfg in configs) {
      final label = cfg['label'] as String;
      final brightness = cfg['brightness'] as Brightness;
      final mode = cfg['mode'] as CustomThemeMode;

      await openEditor(t, label);

      // Ensure we are on the accent tab first
      await tapKey(t, 'editor-tab-accent');
      final accents = swatches(t, 'accent');
      expect(
        accents,
        isNotEmpty,
        reason: 'No accent swatches found for $label',
      );

      await tapKey(t, 'editor-tab-background');
      final backgrounds = swatches(t, 'background');
      expect(
        backgrounds,
        isNotEmpty,
        reason: 'No background swatches found for $label',
      );

      await tapKey(t, 'editor-tab-mine');
      final mines = swatches(t, 'mine');
      expect(mines, isNotEmpty, reason: 'No mine swatches found for $label');

      // Switch mode
      await t.tap(
        find.descendant(of: byKey('editor-mode'), matching: find.text(label)),
      );
      await t.pumpAndSettle();

      await tapKey(t, 'editor-save');

      final saved = look(t).customThemes.singleWhere((x) => x.name == label);
      expect(saved.mode, mode, reason: 'Saved mode mismatch for $label');

      final List<String> failures = [];

      for (final a in accents) {
        for (final bg in [null, ...backgrounds]) {
          for (final m in mines) {
            final theme = CustomTheme(
              id: 'x',
              name: 'x',
              mode: mode,
              accent: a,
              mine: m,
              theirs: saved.theirs,
              background: bg,
            );
            final brand = sisBrandForCustom(theme, brightness);

            // onMine contrast
            final onMineContrast = contrastRatio(
              brand.onMine.toARGB32(),
              Color(m).toARGB32(),
            );
            if (onMineContrast < textMinContrast) {
              failures.add(
                '$label: onMine contrast ${onMineContrast.toStringAsFixed(2)} < $textMinContrast '
                'for accent ${a.toRadixString(16).padLeft(6, '0').toUpperCase()}, '
                'mine ${m.toRadixString(16).padLeft(6, '0').toUpperCase()}',
              );
            }

            // onTheirs contrast
            final onTheirsContrast = contrastRatio(
              brand.onTheirs.toARGB32(),
              brand.theirs.toARGB32(),
            );
            if (onTheirsContrast < textMinContrast) {
              failures.add(
                '$label: onTheirs contrast ${onTheirsContrast.toStringAsFixed(2)} < $textMinContrast '
                'for accent ${a.toRadixString(16).padLeft(6, '0').toUpperCase()}, '
                'theirs ${brand.theirs.toARGB32().toRadixString(16).padLeft(6, '0').toUpperCase()}',
              );
            }

            // chat background and contrast
            final expectedChatBg = bg == null ? null : Color(bg);
            if (brand.chatBackground != expectedChatBg) {
              failures.add(
                '$label: chatBackground mismatch for background '
                '${bg == null ? 'null' : bg.toRadixString(16).padLeft(6, '0').toUpperCase()}',
              );
            }
            if (brand.chatBackground != null) {
              final chatContrast = contrastRatio(
                brand.onChat!.toARGB32(),
                brand.chatBackground!.toARGB32(),
              );
              if (chatContrast < textMinContrast) {
                failures.add(
                  '$label: onChat contrast ${chatContrast.toStringAsFixed(2)} < $textMinContrast '
                  'for background ${bg!.toRadixString(16).padLeft(6, '0').toUpperCase()}, '
                  'chatBackground ${brand.chatBackground!.toARGB32().toRadixString(16).padLeft(6, '0').toUpperCase()}',
                );
              }
            }
          }
        }
      }

      expect(failures, isEmpty, reason: failures.join('\n'));
    }
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';

import 'custom_themes_page_test.dart'
    show pumpApp, look, byKey, under, tapKey, openAppearance;

Future<void> openCard(WidgetTester t) async {
  await openAppearance(t);
  await tapKey(t, 'appearance-new-theme');
}

Set<CustomThemeMode> modeOf(WidgetTester t) =>
    t.widget<SegmentedButton<CustomThemeMode>>(byKey('editor-mode')).selected;

void main() {
  final titles = {
    AppLanguage.en: 'Create a new theme',
    AppLanguage.tr: 'Yeni tema olu\u015ftur',
  };
  final createLabels = {
    AppLanguage.en: 'Create',
    AppLanguage.tr: 'Olu\u015ftur',
  };
  final emptyTexts = {
    AppLanguage.en: 'Name cannot be empty',
    AppLanguage.tr: 'Ad bo\u015f olamaz',
  };
  final resetLabels = {
    AppLanguage.en: 'Reset to default',
    AppLanguage.tr: 'Varsay\u0131lana s\u0131f\u0131rla',
  };
  final accentLabels = {
    AppLanguage.en: 'Accent Color',
    AppLanguage.tr: 'Vurgu Rengi',
  };
  final bgLabels = {AppLanguage.en: 'Background', AppLanguage.tr: 'Arka Plan'};
  final mineLabels = {
    AppLanguage.en: 'My Messages',
    AppLanguage.tr: 'Mesajlar\u0131m',
  };
  final modeLabels = {
    AppLanguage.en: {'light': 'Light', 'dark': 'Dark', 'auto': 'Auto'},
    AppLanguage.tr: {
      'light': 'A\u00e7\u0131k',
      'dark': 'Koyu',
      'auto': 'Otomatik',
    },
  };

  for (final lang in [AppLanguage.en, AppLanguage.tr]) {
    final title = titles[lang]!;
    final createLabel = createLabels[lang]!;
    final emptyText = emptyTexts[lang]!;
    final resetLabel = resetLabels[lang]!;
    final accentLabel = accentLabels[lang]!;
    final bgLabel = bgLabels[lang]!;
    final mineLabel = mineLabels[lang]!;
    final modeLabelMap = modeLabels[lang]!;

    testWidgets('new theme row opens the name card (${lang.name})', (
      WidgetTester t,
    ) async {
      await pumpApp(t, initial: AppearanceSettings(language: lang));
      await openCard(t);
      expect(byKey('new-theme-card'), findsOneWidget);
      expect(find.text(title), findsOneWidget);
      expect(under('new-theme-create', createLabel), findsOneWidget);
    });

    testWidgets('empty name is refused (${lang.name})', (WidgetTester t) async {
      await pumpApp(t, initial: AppearanceSettings(language: lang));
      final before = look(t);
      await openCard(t);
      await tapKey(t, 'new-theme-create');
      expect(byKey('new-theme-card'), findsOneWidget);
      expect(under('new-theme-empty', emptyText), findsOneWidget);
      expect(byKey('editor-preview'), findsNothing);
      expect(look(t), equals(before));
    });

    testWidgets('blank name is refused (${lang.name})', (WidgetTester t) async {
      await pumpApp(t, initial: AppearanceSettings(language: lang));
      final before = look(t);
      await openCard(t);
      await t.enterText(byKey('new-theme-field'), '   ');
      await tapKey(t, 'new-theme-create');
      expect(byKey('new-theme-card'), findsOneWidget);
      expect(under('new-theme-empty', emptyText), findsOneWidget);
      expect(byKey('editor-preview'), findsNothing);
      expect(look(t), equals(before));
    });

    testWidgets('cancel closes and changes nothing (${lang.name})', (
      WidgetTester t,
    ) async {
      await pumpApp(t, initial: AppearanceSettings(language: lang));
      final before = look(t);
      await openCard(t);
      await t.enterText(byKey('new-theme-field'), 'X');
      await tapKey(t, 'new-theme-cancel');
      expect(byKey('new-theme-card'), findsNothing);
      expect(byKey('editor-preview'), findsNothing);
      expect(look(t), equals(before));
    });

    testWidgets('a valid name opens the editor in Light (${lang.name})', (
      WidgetTester t,
    ) async {
      await pumpApp(t, initial: AppearanceSettings(language: lang));
      await openCard(t);
      await t.enterText(byKey('new-theme-field'), 'Sea');
      await tapKey(t, 'new-theme-create');
      expect(byKey('editor-preview'), findsOneWidget);
      expect(byKey('editor-preview-theirs'), findsOneWidget);
      expect(byKey('editor-preview-mine'), findsOneWidget);
      expect(under('editor-tab-accent', accentLabel), findsOneWidget);
      expect(under('editor-tab-background', bgLabel), findsOneWidget);
      expect(under('editor-tab-mine', mineLabel), findsOneWidget);
      expect(modeOf(t), equals({CustomThemeMode.light}));
      expect(under('editor-reset', resetLabel), findsOneWidget);
      for (final label in modeLabelMap.values) {
        expect(
          find.descendant(of: byKey('editor-mode'), matching: find.text(label)),
          findsOneWidget,
        );
      }
    });
  }

  for (final (w, h) in [(360.0, 780.0), (411.0, 914.0)]) {
    for (final lang in [AppLanguage.en, AppLanguage.tr]) {
      testWidgets(
        'name card and editor fit a ${w.toInt()}-wide phone (${lang.name})',
        (WidgetTester t) async {
          t.view
            ..physicalSize = Size(w * 3, h * 3)
            ..devicePixelRatio = 3;
          addTearDown(t.view.reset);
          await pumpApp(t, initial: AppearanceSettings(language: lang));
          await openCard(t);
          expect(t.takeException(), isNull, reason: 'name card overflows');
          await t.enterText(byKey('new-theme-field'), 'Sea');
          await tapKey(t, 'new-theme-create');
          expect(byKey('editor-preview'), findsOneWidget);
          expect(t.takeException(), isNull, reason: 'editor overflows');
        },
      );
    }
  }
}

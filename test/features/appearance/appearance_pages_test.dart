// Appearance, Text size and Language pages and the settings rows that open
// them, written from the contract. Mounted as main.dart mounts the app — SisApp
// behind the session gate, the real SharedPreferences store (in-memory
// platform), fakes only at the repository boundary.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/grey_option.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/home/presentation/home_screen.dart';

import '../../support/design_fakes.dart';

const ela = Member(userId: 'u2', displayName: 'Ela Demir', tag: 'ela');

Message msg(String id, String from, String body, int minute) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 23, 9, minute),
);

DesignChat world() => DesignChat(
  list: [const Conversation(id: 'c1', other: ela, lastMessage: 'Perfect')],
  people: [ela],
  history: {
    'c1': [
      msg('m1', 'u2', 'Are we still on for Saturday?', 1),
      msg('m2', 'u1', 'Yes! 10am at the market', 2),
    ],
  },
);

Finder byKey(String k) => find.byKey(ValueKey(k));
Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text), matchRoot: true);

Future<void> pumpApp(
  WidgetTester t, {
  AppearanceSettings initial = const AppearanceSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  await t.pumpWidget(
    designApp(
      auth: DesignAuth(session: true),
      chat: world(),
      extra: [
        appearanceStoreProvider.overrideWithValue(
          const SharedPrefsAppearanceStore(),
        ),
        initialAppearanceProvider.overrideWithValue(initial),
      ],
    ),
  );
  await t.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget, reason: 'home did not open');
}

AppearanceSettings look(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)))
        .read(appearanceProvider);

/// The theme and text scale everything under the app's navigator sees.
BuildContext appContext(WidgetTester t) =>
    t.element(find.byType(Navigator).first);

/// Scrolls the page on top until [f] is built and on screen (pages are lazy
/// lists): down first, then back up.
Future<void> reveal(WidgetTester t, Finder f) async {
  for (final dy in [-150.0, 150.0]) {
    for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
      await t.drag(find.byType(Scaffold).last, Offset(0, dy));
      await t.pumpAndSettle();
    }
  }
  await t.ensureVisible(f);
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await reveal(t, byKey(key));
  await t.pumpAndSettle();
  await t.tap(byKey(key));
  await t.pumpAndSettle();
}

Future<void> openSettings(WidgetTester t) => tapKey(t, 'home-settings');

Future<void> back(WidgetTester t) async {
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
}

Future<void> segment(WidgetTester t, String key, String label) async {
  await reveal(t, byKey(key));
  final f = find.descendant(of: byKey(key), matching: find.text(label));
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

double scaleAt(WidgetTester t, Finder f) =>
    MediaQuery.textScalerOf(t.element(f)).scale(10);

final checks = {
  Icons.check,
  Icons.check_rounded,
  Icons.check_circle,
  Icons.check_circle_rounded,
  Icons.check_circle_outline,
  Icons.done,
  Icons.done_rounded,
};

bool hasCheck(Finder tile) => find
    .descendant(
      of: tile,
      matching: find.byWidgetPredicate(
        (w) => w is Icon && checks.contains(w.icon),
      ),
    )
    .evaluate()
    .isNotEmpty;

/// Whether a non-zero blur is painted under [tile].
bool isBlurred(Finder tile) => find
    .descendant(
      of: tile,
      matching: find.byWidgetPredicate(
        (w) => switch (w) {
          ImageFiltered(:final imageFilter, :final enabled) =>
            enabled && blurs(imageFilter),
          BackdropFilter(:final filter, :final enabled) =>
            enabled && blurs(filter),
          _ => false,
        },
      ),
    )
    .evaluate()
    .isNotEmpty;

bool blurs(Object? filter) {
  final s = filter.toString();
  return s.contains('blur') && !RegExp(r'blur\(0(\.0)?, 0(\.0)?').hasMatch(s);
}

Color brand(AppThemeId id) => sisBrandFor(id, Brightness.light).brand;

void main() {
  group('settings rows', () {
    testWidgets('all rows, with the current values', (t) async {
      await pumpApp(t);
      await openSettings(t);
      for (final k in [
        'settings-privacy',
        'settings-notifications',
        'settings-account',
        'settings-about',
        'settings-appearance',
        'settings-text-size',
        'settings-language',
      ]) {
        await reveal(t, byKey(k));
        expect(byKey(k), findsOneWidget, reason: k);
      }
      expect(under('settings-appearance', 'Violet'), findsOneWidget);
      expect(under('settings-text-size', 'Medium'), findsOneWidget);
      expect(under('settings-language', 'System'), findsOneWidget);
    });

    testWidgets('values follow stored settings', (t) async {
      await pumpApp(
        t,
        initial: const AppearanceSettings(
          themeId: AppThemeId.graphite,
          chatTextSize: TextSize.large,
          appTextSize: TextSize.small,
          language: AppLanguage.en,
        ),
      );
      await openSettings(t);
      await reveal(t, byKey('settings-language'));
      expect(under('settings-appearance', 'Graphite'), findsOneWidget);
      expect(
        under('settings-text-size', 'Large'),
        findsOneWidget,
        reason: 'the row shows the chat size, not the app size',
      );
      expect(under('settings-language', 'English'), findsOneWidget);
    });
  });

  group('appearance page', () {
    testWidgets('six tiles; the selected has a check, the rest are blurred', (
      t,
    ) async {
      await pumpApp(
        t,
        initial: const AppearanceSettings(themeId: AppThemeId.forest),
      );
      await openSettings(t);
      await tapKey(t, 'settings-appearance');
      for (final id in AppThemeId.values) {
        final tile = byKey('theme-${id.name}');
        await reveal(t, tile);
        expect(tile, findsOneWidget, reason: id.name);
        final selected = id == AppThemeId.forest;
        expect(hasCheck(tile), selected, reason: '${id.name} check badge');
        expect(isBlurred(tile), !selected, reason: '${id.name} blur');
      }
      await reveal(t, byKey('appearance-no-export'));
      expect(
        under(
          'appearance-no-export',
          'Themes stay on this phone. There is no export.',
        ),
        findsOneWidget,
      );
      await reveal(t, byKey('chat-preview'));
      expect(byKey('chat-preview'), findsOneWidget);
    });

    testWidgets('choosing a theme applies at once and moves the check', (
      t,
    ) async {
      await pumpApp(t);
      expect(
        Theme.of(appContext(t)).colorScheme.primary,
        brand(AppThemeId.violet),
      );
      await openSettings(t);
      await tapKey(t, 'settings-appearance');
      await tapKey(t, 'theme-ocean');

      expect(look(t).themeId, AppThemeId.ocean);
      await reveal(t, byKey('chat-preview'));
      expect(
        Theme.of(t.element(byKey('chat-preview'))).colorScheme.primary,
        brand(AppThemeId.ocean),
        reason: 'the preview shows the chosen theme',
      );
      expect(
        Theme.of(appContext(t)).colorScheme.primary,
        brand(AppThemeId.ocean),
      );
      expect(hasCheck(byKey('theme-ocean')), isTrue);
      expect(hasCheck(byKey('theme-violet')), isFalse);
      expect(isBlurred(byKey('theme-violet')), isTrue);

      await back(t);
      expect(under('settings-appearance', 'Ocean'), findsOneWidget);
    });
  });

  group('text size page', () {
    testWidgets('system font off switches the app to Manrope', (t) async {
      await pumpApp(t);
      expect(
        Theme.of(appContext(t)).textTheme.bodyMedium?.fontFamily,
        isNot('Manrope'),
      );
      await openSettings(t);
      await tapKey(t, 'settings-text-size');
      await tapKey(t, 'text-system-font');
      expect(look(t).systemFont, isFalse);
      expect(
        Theme.of(appContext(t)).textTheme.bodyMedium?.fontFamily,
        'Manrope',
      );
      await tapKey(t, 'text-system-font');
      expect(look(t).systemFont, isTrue);
      expect(
        Theme.of(appContext(t)).textTheme.bodyMedium?.fontFamily,
        isNot('Manrope'),
      );
    });

    testWidgets('chat and app sizes are separate; the preview is chat size', (
      t,
    ) async {
      t.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpApp(t);
      await openSettings(t);
      await tapKey(t, 'settings-text-size');

      await segment(t, 'text-chat-size', 'Large');
      await segment(t, 'text-app-size', 'Small');
      expect(look(t).chatTextSize, TextSize.large);
      expect(look(t).appTextSize, TextSize.small);

      // The system scale times the chosen size.
      await reveal(t, byKey('text-app-sample'));
      expect(
        scaleAt(t, byKey('text-app-sample')),
        closeTo(10 * 1.5 * 0.88, 1e-6),
      );
      await reveal(t, byKey('chat-preview'));
      final bubbleText = find.descendant(
        of: byKey('chat-preview'),
        matching: find.byType(Text),
      );
      expect(bubbleText, findsWidgets);
      expect(scaleAt(t, bubbleText.first), closeTo(10 * 1.5 * 1.2, 1e-6));

      await back(t);
      expect(under('settings-text-size', 'Large'), findsOneWidget);
    });
  });

  group('language page', () {
    void phone(WidgetTester t, Locale l) {
      t.platformDispatcher.localesTestValue = [l];
      addTearDown(t.platformDispatcher.clearLocalesTestValue);
    }

    testWidgets('system follows the phone; a choice overrides it', (t) async {
      phone(t, const Locale('tr'));
      await pumpApp(t);
      await openSettings(t);
      expect(under('settings-appearance', 'Görünüm'), findsOneWidget);

      await tapKey(t, 'settings-language');
      expect(byKey('language-system'), findsOneWidget);
      await tapKey(t, 'language-en');
      expect(look(t).language, AppLanguage.en);
      expect(Localizations.localeOf(appContext(t)), const Locale('en'));
      await back(t);
      expect(under('settings-appearance', 'Appearance'), findsOneWidget);
      expect(under('settings-language', 'English'), findsOneWidget);

      await tapKey(t, 'settings-language');
      await tapKey(t, 'language-system');
      expect(look(t).language, AppLanguage.system);
      await back(t);
      expect(under('settings-appearance', 'Görünüm'), findsOneWidget);
      expect(under('settings-language', 'Sistem'), findsOneWidget);
    });

    testWidgets('Turkish on an English phone', (t) async {
      phone(t, const Locale('en', 'US'));
      await pumpApp(t);
      await openSettings(t);
      await tapKey(t, 'settings-language');
      await tapKey(t, 'language-tr');
      expect(look(t).language, AppLanguage.tr);
      expect(Localizations.localeOf(appContext(t)), const Locale('tr'));
      await back(t);
      expect(under('settings-appearance', 'Görünüm'), findsOneWidget);
      expect(under('settings-language', 'Türkçe'), findsOneWidget);
    });
  });

  group('grey options', () {
    const where = {
      'grey-att_auto': null, // on the settings page itself
    };

    for (final MapEntry(key: grey, value: page) in where.entries) {
      for (final lang in [AppLanguage.en, AppLanguage.tr]) {
        testWidgets('$grey (${lang.name}): inert, disabled, unfocusable, '
            'no "soon"', (t) async {
          final semantics = t.ensureSemantics();
          await pumpApp(t, initial: AppearanceSettings(language: lang));
          await openSettings(t);
          if (page != null) await tapKey(t, page);
          final f = byKey(grey);
          await reveal(t, f);
          expect(f, findsOneWidget);

          // No "soon" label, in any wording.
          final texts = find
              .descendant(of: f, matching: find.byType(Text))
              .evaluate()
              .map((e) => (e.widget as Text).data ?? '')
              .join(' ')
              .toLowerCase();
          expect(texts, isNot(contains('soon')));
          expect(texts, isNot(contains('yakında')));

          expect(
            t.getSemantics(f),
            isSemantics(
              hasEnabledState: true,
              isEnabled: false,
              isFocusable: false,
              hasTapAction: false,
            ),
          );

          // Tapping does nothing: no page opens, no setting changes.
          final before = look(t);
          final route = ModalRoute.of(t.element(f))!;
          await t.tap(f, warnIfMissed: false);
          await t.pumpAndSettle();
          expect(route.isCurrent, isTrue, reason: 'a page opened');
          expect(look(t), before);

          // Keyboard traversal never lands inside it.
          for (var i = 0; i < 40; i++) {
            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.pump();
            final ctx = FocusManager.instance.primaryFocus?.context;
            if (ctx == null) continue;
            final inside = find
                .descendant(
                  of: f,
                  matching: find.byWidget(ctx.widget),
                  matchRoot: true,
                )
                .evaluate()
                .isNotEmpty;
            expect(inside, isFalse, reason: 'focus reached $grey');
          }
          semantics.dispose();
        });
      }
    }

    for (final lang in [AppLanguage.en, AppLanguage.tr]) {
      testWidgets(
        'new theme row (${lang.name}): enabled, opens the name card',
        (t) async {
          final semantics = t.ensureSemantics();
          await pumpApp(t, initial: AppearanceSettings(language: lang));
          await openSettings(t);
          await tapKey(t, 'settings-appearance');
          final f = byKey('appearance-new-theme');
          await reveal(t, f);
          expect(f, findsOneWidget);
          expect(t.getSemantics(f), isSemantics(hasTapAction: true));
          await t.tap(f);
          await t.pumpAndSettle();
          expect(byKey('new-theme-card'), findsOneWidget);
          semantics.dispose();
        },
      );
    }
  });

  group('GreyOption itself', () {
    // The pages pass children that are inert already; this proves the wrapper
    // makes a live, focusable child inert too.
    testWidgets('swallows taps and focus of a live child', (t) async {
      final semantics = t.ensureSemantics();
      var taps = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  key: const ValueKey('live'),
                  onPressed: () {},
                  child: const Text('Live'),
                ),
                GreyOption(
                  name: 'probe',
                  label: 'Probe',
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('Grey'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final grey = byKey('grey-probe');
      await t.tap(find.text('Grey'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(taps, 0, reason: 'the tap reached the child');

      expect(
        t.getSemantics(grey),
        isSemantics(
          label: 'Probe',
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: false,
          hasTapAction: false,
        ),
      );

      var reachedLive = false;
      for (var i = 0; i < 6; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        final ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) continue;
        final at = find.byWidget(ctx.widget);
        if (find
            .descendant(of: byKey('live'), matching: at, matchRoot: true)
            .evaluate()
            .isNotEmpty) {
          reachedLive = true;
        }
        expect(
          find.descendant(of: grey, matching: at, matchRoot: true).evaluate(),
          isEmpty,
          reason: 'focus reached the grey child',
        );
      }
      expect(reachedLive, isTrue, reason: 'Tab traversal never ran');
      semantics.dispose();
    });
  });

  group('message screen', () {
    testWidgets('messages are chat size, the list is app size', (t) async {
      await pumpApp(
        t,
        initial: const AppearanceSettings(
          chatTextSize: TextSize.large,
          appTextSize: TextSize.small,
        ),
      );
      final listText = find.descendant(
        of: byKey('conversation-c1'),
        matching: find.text('Perfect'),
      );
      expect(scaleAt(t, listText), closeTo(8.8, 1e-6));

      await t.tap(byKey('conversation-c1'));
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
      final body = find.descendant(
        of: byKey('message-m2'),
        matching: find.text('Yes! 10am at the market'),
      );
      expect(scaleAt(t, body), closeTo(12, 1e-6));
    });
  });
}

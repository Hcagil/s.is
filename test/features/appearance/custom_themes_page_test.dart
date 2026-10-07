// test/features/appearance/custom_themes_page_test.dart
//
// This file tests the custom themes page behaviour. It re‑uses the helpers
// from chat_wallpaper_screens_test.dart and adds a few more for theme
// specific assertions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper_photos.dart';
import 'package:sis/features/appearance/presentation/wallpaper_page.dart';

import '../../support/design_fakes.dart';

const ela = Member(userId: 'u2', displayName: 'Ela Demir', tag: 'ela');

Finder byKey(String k) => find.byKey(ValueKey(k));

/// Fake implementation of the wallpaper photo picker.
class FakePhotos implements WallpaperPhotos {
  @override
  Future<WallpaperPick> pick() async => const WallpaperPickCancelled();

  @override
  Future<void> delete(String path) async {}
}

/// Helper to create a message with an explicit conversation id.
Message msg2(
  String conversationId,
  String id,
  String senderId,
  String body,
  int minute,
) => Message(
  id: id,
  conversationId: conversationId,
  senderId: senderId,
  body: body,
  createdAt: DateTime.utc(2026, 9, 23, 9, minute),
);

/// World containing a 1:1, a group and a system chat.
DesignChat world() => DesignChat(
  list: const [
    Conversation(id: 'c1', other: ela, lastMessage: 'Perfect'),
    Conversation(id: 'g1', title: 'Club', lastMessage: 'yo'),
    Conversation(
      id: 's1',
      isSystem: true,
      lastMessage: 'Notifications are grouped now.',
    ),
  ],
  people: [ela],
  history: {
    'c1': [msg2('c1', 'm1', 'u2', 'Are we still on for Saturday?', 1)],
    'g1': [msg2('g1', 'm2', 'u2', 'yo', 2)],
    's1': [
      msg2(
        's1',
        'm3',
        '00000000-0000-0000-0000-00000000515e',
        'Notifications are grouped now.',
        3,
      ),
    ],
  },
);

/// Pump the app with the world and optional initial settings.
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
        wallpaperPhotosProvider.overrideWithValue(FakePhotos()),
      ],
    ),
  );
  await t.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget, reason: 'home did not open');
}

/// Custom theme helpers for the tests below.
AppearanceSettings look(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)))
        .read(appearanceProvider);

BuildContext appContext(WidgetTester t) =>
    t.element(find.byType(Navigator).first);

Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text), matchRoot: true);

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
  await t.tap(byKey(key));
  await t.pumpAndSettle();
}

Future<void> openAppearance(WidgetTester t) async {
  await tapKey(t, 'home-settings');
  await tapKey(t, 'settings-appearance');
}

bool hasCheck(Finder tile) => find
    .descendant(
      of: tile,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Icon &&
            {
              Icons.check,
              Icons.check_rounded,
              Icons.check_circle,
              Icons.check_circle_rounded,
              Icons.check_circle_outline,
              Icons.done,
              Icons.done_rounded,
            }.contains(w.icon),
      ),
    )
    .evaluate()
    .isNotEmpty;

/// Fixtures
const night = CustomTheme(
  id: 'n1',
  name: 'Night',
  mode: CustomThemeMode.dark,
  accent: 0xFF2E7D32,
  mine: 0xFF1B5E20,
  theirs: 0xFF263238,
);
const day = CustomTheme(
  id: 'd1',
  name: 'Day',
  mode: CustomThemeMode.light,
  accent: 0xFFE65100,
  mine: 0xFFFFCC80,
  theirs: 0xFFFFFFFF,
);

void main() {
  group('custom themes page', () {
    testWidgets('initial selection', (t) async {
      await pumpApp(
        t,
        initial: AppearanceSettings(
          customThemes: [night, day],
          customThemeId: 'n1',
        ),
      );
      await openAppearance(t);
      await reveal(t, byKey('custom-theme-n1'));
      await reveal(t, byKey('custom-theme-d1'));
      expect(find.byKey(ValueKey('custom-theme-n1')), findsOneWidget);
      expect(find.byKey(ValueKey('custom-theme-d1')), findsOneWidget);
      expect(under('custom-theme-n1', 'Night'), findsOneWidget);
      expect(hasCheck(byKey('custom-theme-n1')), isTrue);
      expect(hasCheck(byKey('custom-theme-d1')), isFalse);
      for (final id in AppThemeId.values) {
        await reveal(t, byKey('theme-${id.name}'));
        expect(hasCheck(byKey('theme-${id.name}')), isFalse);
      }
    });

    testWidgets('select custom and built‑in', (t) async {
      await pumpApp(
        t,
        initial: AppearanceSettings(
          customThemes: [night, day],
          customThemeId: 'n1',
        ),
      );
      await openAppearance(t);
      await tapKey(t, 'custom-theme-d1');
      expect(look(t).customThemeId, equals('d1'));
      await tapKey(t, 'theme-ocean');
      expect(look(t).customThemeId, isNull);
      expect(look(t).themeId, equals(AppThemeId.ocean));
      expect(look(t).customThemes.length, equals(2));
    });

    testWidgets('settings row shows active theme', (t) async {
      await pumpApp(
        t,
        initial: AppearanceSettings(
          customThemes: [night, day],
          customThemeId: 'n1',
        ),
      );
      await tapKey(t, 'home-settings');
      expect(under('settings-appearance', 'Night'), findsOneWidget);
    });

    testWidgets('settings row shows the built-in label otherwise', (t) async {
      await pumpApp(
        t,
        initial: AppearanceSettings(
          themeId: AppThemeId.forest,
          customThemes: [night],
        ),
      );
      await tapKey(t, 'home-settings');
      expect(under('settings-appearance', 'Forest'), findsOneWidget);
    });

    testWidgets('long‑press creates copy (EN)', (t) async {
      await pumpApp(t);
      await openAppearance(t);
      await reveal(t, byKey('theme-ocean'));
      await t.longPress(byKey('theme-ocean'));
      await t.pumpAndSettle();
      final s = look(t);
      expect(s.customThemes.length, equals(1));
      final copy = s.customThemes.single;
      expect(copy.name, equals('Ocean copy'));
      expect(copy.mode, equals(CustomThemeMode.automatic));
      expect(s.customThemeId, equals(copy.id));
      await reveal(t, byKey('custom-theme-${copy.id}'));
      expect(find.byKey(ValueKey('custom-theme-${copy.id}')), findsOneWidget);
    });

    testWidgets('long‑press creates copy (TR)', (t) async {
      await pumpApp(t, initial: AppearanceSettings(language: AppLanguage.tr));
      await openAppearance(t);
      await reveal(t, byKey('theme-ocean'));
      await t.longPress(byKey('theme-ocean'));
      await t.pumpAndSettle();
      final s = look(t);
      final copy = s.customThemes.single;
      expect(copy.name, equals('Okyanus kopyası'));
    });

    testWidgets('new theme row opens the name card and changes nothing yet', (
      t,
    ) async {
      await pumpApp(
        t,
        initial: AppearanceSettings(
          customThemes: [night, day],
          customThemeId: 'n1',
        ),
      );
      await openAppearance(t);
      final before = look(t);
      await tapKey(t, 'appearance-new-theme');
      expect(byKey('new-theme-card'), findsOneWidget);
      expect(look(t), equals(before));
    });

    testWidgets('wallpaper page opens', (t) async {
      await pumpApp(
        t,
        initial: AppearanceSettings(
          customThemes: [night, day],
          customThemeId: 'n1',
        ),
      );
      await openAppearance(t);
      await tapKey(t, 'appearance-wallpaper');
      expect(find.byType(WallpaperPage), findsOneWidget);
    });

    group('theme mode', () {
      testWidgets('phone light (default) with dark custom theme', (t) async {
        await pumpApp(
          t,
          initial: AppearanceSettings(
            customThemes: [night],
            customThemeId: 'n1',
          ),
        );
        expect(Theme.of(appContext(t)).brightness, equals(Brightness.dark));
      });

      testWidgets('phone dark with light custom theme', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        await pumpApp(
          t,
          initial: AppearanceSettings(customThemes: [day], customThemeId: 'd1'),
        );
        expect(Theme.of(appContext(t)).brightness, equals(Brightness.light));
      });

      const auto = CustomTheme(
        id: 'a1',
        name: 'Auto',
        mode: CustomThemeMode.automatic,
        accent: 0xFF0000FF,
        mine: 0xFF000080,
        theirs: 0xFFFFFFFF,
      );

      testWidgets('automatic theme on phone dark', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        await pumpApp(
          t,
          initial: AppearanceSettings(
            customThemes: [auto],
            customThemeId: 'a1',
          ),
        );
        expect(Theme.of(appContext(t)).brightness, equals(Brightness.dark));
      });

      testWidgets('automatic theme on phone light', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        await pumpApp(
          t,
          initial: AppearanceSettings(
            customThemes: [auto],
            customThemeId: 'a1',
          ),
        );
        expect(Theme.of(appContext(t)).brightness, equals(Brightness.light));
      });
    });
  });
}

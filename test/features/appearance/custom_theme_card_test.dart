// test/features/appearance/custom_theme_card_test.dart
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
import 'package:sis/app/theme.dart';

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

Future<void> openMenu(WidgetTester t, String id) async {
  await openAppearance(t);
  await tapKey(t, 'custom-theme-menu-$id');
}

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
const initial = AppearanceSettings(
  themeId: AppThemeId.rose,
  customThemes: [night],
  customThemeId: 'n1',
);

Future<void> openRename(WidgetTester t, String text) async {
  await pumpApp(t, initial: initial);
  await openMenu(t, 'n1');
  await tapKey(t, 'theme-rename');
  expect(byKey('theme-rename-card'), findsOneWidget);
  await t.enterText(byKey('theme-rename-field'), text);
  await t.pumpAndSettle();
}

void main() {
  group('custom theme card', () {
    testWidgets('the dots open the card; opening it changes nothing', (
      t,
    ) async {
      await pumpApp(t, initial: initial);
      await openMenu(t, 'n1');
      for (final k in [
        'custom-theme-card',
        'theme-rename',
        'theme-duplicate',
        'theme-delete',
      ]) {
        expect(byKey(k), findsOneWidget, reason: k);
      }
      expect(under('theme-rename', 'Rename'), findsOneWidget);
      expect(under('theme-duplicate', 'Duplicate'), findsOneWidget);
      expect(under('theme-delete', 'Delete'), findsOneWidget);
      expect(look(t), initial);
    });

    testWidgets('TR labels', (t) async {
      await pumpApp(
        t,
        initial: const AppearanceSettings(
          language: AppLanguage.tr,
          customThemes: [night],
          customThemeId: 'n1',
        ),
      );
      await openMenu(t, 'n1');
      expect(under('theme-rename', 'Yeniden adlandır'), findsOneWidget);
      expect(under('theme-duplicate', 'Çoğalt'), findsOneWidget);
      expect(under('theme-delete', 'Sil'), findsOneWidget);
    });
  });

  group('rename card', () {
    testWidgets('save renames the tile', (t) async {
      await openRename(t, 'Dusk');
      await tapKey(t, 'theme-rename-save');
      expect(byKey('theme-rename-card'), findsNothing);
      expect(look(t).customThemes.single.name, 'Dusk');
      await reveal(t, byKey('custom-theme-n1'));
      expect(under('custom-theme-n1', 'Dusk'), findsOneWidget);
    });

    testWidgets('cancel keeps the name', (t) async {
      await openRename(t, 'Other');
      await tapKey(t, 'theme-rename-cancel');
      expect(byKey('theme-rename-card'), findsNothing);
      expect(look(t).customThemes.single.name, 'Night');
    });

    testWidgets('a blank name is not saved', (t) async {
      await openRename(t, '   ');
      await t.tap(byKey('theme-rename-save'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(look(t).customThemes.single.name, 'Night');
    });
  });

  group('duplicate and delete', () {
    testWidgets('duplicate appends a copy and keeps the selection', (t) async {
      await pumpApp(t, initial: initial);
      await openMenu(t, 'n1');
      await tapKey(t, 'theme-duplicate');
      final s = look(t);
      expect(s.customThemes, hasLength(2));
      expect(s.customThemeId, 'n1');
      final copy = s.customThemes.last;
      expect(copy.id, isNot('n1'));
      expect(
        (copy.mode, copy.accent, copy.mine, copy.theirs),
        (night.mode, night.accent, night.mine, night.theirs),
      );
      await reveal(t, byKey('custom-theme-${copy.id}'));
      expect(byKey('custom-theme-${copy.id}'), findsOneWidget);
    });

    testWidgets('deleting the selected theme brings the built-in back', (
      t,
    ) async {
      await pumpApp(t, initial: initial);
      expect(Theme.of(appContext(t)).brightness, Brightness.dark);
      await openMenu(t, 'n1');
      await tapKey(t, 'theme-delete');
      final s = look(t);
      expect(s.customThemes, isEmpty);
      expect(s.customThemeId, isNull);
      expect(s.themeId, AppThemeId.rose);
      expect(byKey('custom-theme-n1'), findsNothing);
      final theme = Theme.of(appContext(t));
      expect(theme.brightness, Brightness.light);
      expect(
        theme.colorScheme.primary,
        sisBrandFor(AppThemeId.rose, Brightness.light).brand,
      );
    });

    testWidgets('deleting another theme keeps the selection', (t) async {
      await pumpApp(
        t,
        initial: const AppearanceSettings(
          customThemes: [night, day],
          customThemeId: 'n1',
        ),
      );
      await openMenu(t, 'd1');
      await tapKey(t, 'theme-delete');
      expect(look(t).customThemes.single.id, 'n1');
      expect(look(t).customThemeId, 'n1');
    });
  });
}

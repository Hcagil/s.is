// test/features/appearance/chat_wallpaper_screens_test.dart
//
// This file tests the wallpaper behaviour behind the message list in
// 1:1, group and system chats.  It re‑uses the helpers from
// appearance_pages_test.dart and adds the wallpaper related logic.

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
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper_photos.dart';

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

/// Helper to open a conversation and wait for the message screen.
Future<void> openChat(WidgetTester t, String id) async {
  await t.tap(byKey('conversation-$id'));
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  expect(find.byType(MessageScreen), findsOneWidget);
}

/// Helper to close the message screen.
Future<void> closeChat(WidgetTester t) async {
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
}

/// Finder for the wallpaper widget.
Finder get wall => find.descendant(
  of: find.byType(MessageScreen),
  matching: byKey('chat-wallpaper'),
);

/// Paint helper from the template.
Set<int> paintedColours(Finder root) {
  final out = <int>{};
  for (final e
      in find
          .descendant(
            of: root,
            matching: find.byWidgetPredicate((_) => true),
            matchRoot: true,
          )
          .evaluate()) {
    final w = e.widget;
    if (w is ColoredBox) out.add(w.color.toARGB32());
    if (w is Container && w.color != null) out.add(w.color!.toARGB32());
    final d = w is DecoratedBox
        ? w.decoration
        : (w is Container ? w.decoration : null);
    if (d is BoxDecoration) {
      if (d.color != null) out.add(d.color!.toARGB32());
      final g = d.gradient;
      if (g != null) out.addAll(g.colors.map((c) => c.toARGB32()));
    }
  }
  return out;
}

Set<int> wallColours() =>
    wall.evaluate().isEmpty ? <int>{} : paintedColours(wall);

void main() {
  const ids = ['c1', 'g1', 's1'];
  for (final id in ids) {
    group('chat $id', () {
      testWidgets('member colour wallpaper', (t) async {
        await pumpApp(
          t,
          initial: AppearanceSettings(
            wallpaper: Wallpaper(
              kind: WallpaperKind.colour,
              colours: [0xFF123456],
            ),
          ),
        );
        await openChat(t, id);
        expect(wallColours(), contains(0xFF123456));
        await closeChat(t);
      });

      testWidgets('member gradient wallpaper', (t) async {
        await pumpApp(
          t,
          initial: AppearanceSettings(
            wallpaper: Wallpaper(
              kind: WallpaperKind.gradient,
              colours: [0xFF101010, 0xFF202020],
            ),
          ),
        );
        await openChat(t, id);
        expect(wallColours(), containsAll([0xFF101010, 0xFF202020]));
        await closeChat(t);
      });

      testWidgets('phone dark, theme ocean, no wallpaper', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        await pumpApp(
          t,
          initial: AppearanceSettings(themeId: AppThemeId.ocean),
        );
        await openChat(t, id);
        expect(wallColours(), containsAll([0xFF0B2A45, 0xFF0A1626]));
        await closeChat(t);
      });

      testWidgets('phone light, theme ocean, no wallpaper', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        await pumpApp(
          t,
          initial: AppearanceSettings(themeId: AppThemeId.ocean),
        );
        await openChat(t, id);
        expect(wallColours().intersection({0xFF0B2A45, 0xFF0A1626}), isEmpty);
        await closeChat(t);
      });

      testWidgets(
        'phone dark, active custom theme, theme ocean, no wallpaper',
        (t) async {
          t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
          addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
          await pumpApp(
            t,
            initial: AppearanceSettings(
              themeId: AppThemeId.ocean,
              customThemes: [
                CustomTheme(
                  id: 'n1',
                  name: 'Night',
                  mode: CustomThemeMode.dark,
                  accent: 0xFF2E7D32,
                  mine: 0xFF1B5E20,
                  theirs: 0xFF263238,
                ),
              ],
              customThemeId: 'n1',
            ),
          );
          await openChat(t, id);
          expect(wallColours().intersection({0xFF0B2A45, 0xFF0A1626}), isEmpty);
          await closeChat(t);
        },
      );

      testWidgets('live wallpaper change', (t) async {
        await pumpApp(t);
        await openChat(t, id);
        expect(wallColours(), isNot(contains(0xFF654321)));
        final notifier = ProviderScope.containerOf(
          t.element(find.byType(SisApp)),
        ).read(appearanceProvider.notifier);
        notifier.setWallpaper(
          const Wallpaper(kind: WallpaperKind.colour, colours: [0xFF654321]),
        );
        await t.pumpAndSettle();
        expect(wallColours(), contains(0xFF654321));
        await closeChat(t);
      });

      if (id == 'c1') {
        testWidgets('wallpaper behind message list', (t) async {
          await pumpApp(
            t,
            initial: AppearanceSettings(
              wallpaper: Wallpaper(
                kind: WallpaperKind.colour,
                colours: [0xFF123456],
              ),
            ),
          );
          await openChat(t, 'c1');
          final textFinder = find.text('Are we still on for Saturday?');
          expect(textFinder.hitTestable(), findsOneWidget);
          // Tap should not throw.
          await t.tap(textFinder, warnIfMissed: true);
          await t.pumpAndSettle();
          await closeChat(t);
        });
      }
    });
  }
}

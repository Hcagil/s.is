// test/features/appearance/wallpaper_reset_and_sliders_test.dart
//
// This test file focuses on the wallpaper reset functionality and the
// dim/blur sliders in the appearance settings.  It re‑uses the helpers
// from the original chat wallpaper test but replaces the photo picker
// with a fake implementation that records deletions.

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

  final deleted = <String>[];

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
  }
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
  required FakePhotos photos,
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
        wallpaperPhotosProvider.overrideWithValue(photos),
      ],
    ),
  );
  await t.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget, reason: 'home did not open');
}

/// Read the current appearance settings from the provider.
AppearanceSettings look(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)))
        .read(appearanceProvider);

/// Scroll until the finder is visible.
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

/// Tap a widget by key, revealing it first.
Future<void> tapKey(WidgetTester t, String key) async {
  await reveal(t, byKey(key));
  await t.tap(byKey(key));
  await t.pumpAndSettle();
}

/// Open the wallpaper settings page.
Future<void> openWallpaper(WidgetTester t) async {
  await tapKey(t, 'home-settings');
  await tapKey(t, 'settings-appearance');
  await tapKey(t, 'appearance-wallpaper');
}

/// Helper to detect blur filters.
bool blurs(Object? filter) {
  final s = filter.toString();
  return s.contains('blur') && !RegExp(r'blur\(0(\.0)?, 0(\.0)?').hasMatch(s);
}

bool blurred(Finder root) => find
    .descendant(
      of: root,
      matching: find.byWidgetPredicate(
        (w) =>
            (w is ImageFiltered && w.enabled && blurs(w.imageFilter)) ||
            (w is BackdropFilter && w.enabled && blurs(w.filter)),
      ),
      matchRoot: true,
    )
    .evaluate()
    .isNotEmpty;

/// Path of the old picture used in tests.
const oldPath = '/data/old.jpg';
const pictureWall = Wallpaper(
  kind: WallpaperKind.picture,
  picturePath: oldPath,
);

void main() {
  group('wallpaper reset and sliders', () {
    testWidgets('sliders', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-picture');
      await reveal(t, byKey('wallpaper-dim'));
      final d = t.widget<Slider>(byKey('wallpaper-dim'));
      expect(d.min, 0);
      expect(d.max, closeTo(0.8, 1e-9));
      d.onChanged!(0.6);
      await t.pumpAndSettle();
      expect(look(t).wallpaper.dim, closeTo(0.6, 1e-9));

      await reveal(t, byKey('wallpaper-blur'));
      final b = t.widget<Slider>(byKey('wallpaper-blur'));
      expect(b.max, closeTo(12, 1e-9));
      expect(blurred(byKey('chat-preview')), isFalse);
      b.onChanged!(8);
      await t.pumpAndSettle();
      expect(look(t).wallpaper.blur, closeTo(8, 1e-9));
      expect(blurred(byKey('chat-preview')), isTrue);
    });

    testWidgets(
      'dim darkens the picture in the preview, by the chosen amount',
      (t) async {
        final photos = FakePhotos();
        await pumpApp(
          t,
          photos: photos,
          initial: AppearanceSettings(
            wallpaper: pictureWall.copyWith(dim: 0.0),
          ),
        );
        await openWallpaper(t);
        await tapKey(t, 'wallpaper-tab-picture');

        double darkest() {
          final boxes = find
              .descendant(
                of: byKey('chat-preview'),
                matching: find.byType(ColoredBox),
                matchRoot: true,
              )
              .evaluate();
          double maxAlpha = 0.0;
          for (final e in boxes) {
            final c = (e.widget as ColoredBox).color;
            if (c.r == 0 && c.g == 0 && c.b == 0) {
              if (c.a > maxAlpha) maxAlpha = c.a;
            }
          }
          return maxAlpha;
        }

        expect(darkest(), lessThan(0.01));

        await reveal(t, byKey('wallpaper-dim'));
        t.widget<Slider>(byKey('wallpaper-dim')).onChanged!(0.6);
        await t.pumpAndSettle();

        expect(look(t).wallpaper.dim, closeTo(0.6, 1e-9));
        expect(darkest(), closeTo(0.6, 0.02));
      },
    );
    testWidgets('reset texts EN', (t) async {
      final photos = FakePhotos();
      await pumpApp(t, photos: photos);
      await openWallpaper(t);
      await reveal(t, byKey('wallpaper-reset'));
      expect(find.text('Reset Chat Backgrounds'), findsOneWidget);
      expect(
        find.text(
          'Remove all uploaded chat backgrounds and restore the pre-installed ones.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reset cancel', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-reset');
      expect(byKey('wallpaper-reset-card'), findsOneWidget);
      expect(find.text('Reset chat backgrounds'), findsOneWidget);
      expect(
        find.text('Are you sure you want to reset all chat backgrounds?'),
        findsOneWidget,
      );
      await tapKey(t, 'wallpaper-reset-cancel');
      expect(byKey('wallpaper-reset-card'), findsNothing);
      expect(look(t).wallpaper, pictureWall);
      expect(photos.deleted, isEmpty);
    });

    testWidgets('reset tap outside', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-reset');
      expect(byKey('wallpaper-reset-card'), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(byKey('wallpaper-reset-card'), findsNothing);
      expect(look(t).wallpaper, pictureWall);
      expect(photos.deleted, isEmpty);
    });

    testWidgets('reset confirm', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-reset');
      expect(byKey('wallpaper-reset-card'), findsOneWidget);
      await tapKey(t, 'wallpaper-reset-confirm');
      expect(look(t).wallpaper, Wallpaper.none);
      expect(photos.deleted, [oldPath]);
      expect(byKey('wallpaper-reset-card'), findsNothing);
    });

    testWidgets('confirm from colour wallpaper', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(
          wallpaper: Wallpaper(
            kind: WallpaperKind.colour,
            colours: [0xFF112233],
          ),
        ),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-reset');
      await tapKey(t, 'wallpaper-reset-confirm');
      expect(look(t).wallpaper, Wallpaper.none);
      expect(photos.deleted, isEmpty);
    });

    testWidgets('keeps custom themes', (t) async {
      final photos = FakePhotos();
      final custom = CustomTheme(
        id: 'n1',
        name: 'Night',
        mode: CustomThemeMode.dark,
        accent: 0xFF2E7D32,
        mine: 0xFF1B5E20,
        theirs: 0xFF263238,
      );
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(
          wallpaper: pictureWall,
          customThemes: [custom],
          customThemeId: 'n1',
        ),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-reset');
      await tapKey(t, 'wallpaper-reset-confirm');
      expect(look(t).wallpaper, Wallpaper.none);
      expect(look(t).customThemes, [custom]);
      expect(look(t).customThemeId, 'n1');
      expect(photos.deleted, [oldPath]);
    });

    testWidgets('TR texts', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos: photos,
        initial: AppearanceSettings(
          language: AppLanguage.tr,
          wallpaper: pictureWall,
        ),
      );
      await openWallpaper(t);
      await reveal(t, byKey('wallpaper-reset'));
      expect(find.text('Sohbet Arka Planlarını Sıfırla'), findsOneWidget);
      await tapKey(t, 'wallpaper-reset');
      expect(find.text('Sohbet arka planlarını sıfırla'), findsOneWidget);
      expect(
        find.text(
          'Tüm sohbet arka planlarını sıfırlamak istediğine emin misin?',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: byKey('wallpaper-reset-confirm'),
          matching: find.text('Sıfırla'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });
  });
}

// test/features/appearance/wallpaper_page_test.dart
// This file tests the wallpaper settings page behaviour.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';
import 'package:sis/features/appearance/domain/wallpaper_photos.dart';
import 'package:sis/features/appearance/presentation/wallpaper_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/home/presentation/home_screen.dart';

import '../../support/design_fakes.dart';

/// Fake implementation of the wallpaper photo picker.
class FakePhotos implements WallpaperPhotos {
  WallpaperPick next = const WallpaperPickCancelled();

  final deleted = <String>[];
  int picks = 0;

  @override
  Future<WallpaperPick> pick() async {
    picks++;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return next;
  }

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
  }
}

/// Helper to create a key finder.
Finder byKey(String k) => find.byKey(ValueKey(k));

/// Pump the app with the world and optional initial settings.
Future<void> pumpApp(
  WidgetTester t,
  FakePhotos photos, {
  AppearanceSettings initial = const AppearanceSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  await t.pumpWidget(
    designApp(
      auth: DesignAuth(session: true),
      chat: DesignChat(list: [], people: [], history: {}),
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

/// Find a widget under a key that contains the given text.
Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text), matchRoot: true);

/// Reveal a widget by dragging the scaffold until it is visible.
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

/// Tap a widget by key, revealing it first if necessary.
Future<void> tapKey(WidgetTester t, String key) async {
  await reveal(t, byKey(key));
  await t.tap(byKey(key));
  await t.pumpAndSettle();
}

/// Open the wallpaper settings page from the home screen.
Future<void> openWallpaper(WidgetTester t) async {
  await tapKey(t, 'home-settings');
  await tapKey(t, 'settings-appearance');
  await tapKey(t, 'appearance-wallpaper');
  expect(find.byType(WallpaperPage), findsOneWidget);
}

/// Helper to collect all ARGB32 colours painted in a subtree.
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

const oldPath = '/data/old.jpg';
const newPath = '/data/new.jpg';
const pictureWall = Wallpaper(
  kind: WallpaperKind.picture,
  picturePath: oldPath,
);

void main() {
  group('WallpaperPage', () {
    testWidgets('colour wallpaper selection', (t) async {
      final photos = FakePhotos();
      await pumpApp(t, photos);
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-colour');
      await tapKey(t, 'wallpaper-colour-3');
      final w = look(t).wallpaper;
      expect(w.kind, WallpaperKind.colour);
      expect(w.colours.length, 1);
      expect(
        paintedColours(byKey('chat-preview')).contains(w.colours.first),
        isTrue,
      );
      final first = w.colours.first;
      await tapKey(t, 'wallpaper-colour-5');
      expect(look(t).wallpaper.colours.first, isNot(first));
    });

    testWidgets('all colour and gradient swatches visible', (t) async {
      final photos = FakePhotos();
      await pumpApp(t, photos);
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-colour');
      for (var i = 0; i < 8; i++) {
        await reveal(t, byKey('wallpaper-colour-$i'));
        expect(find.byKey(ValueKey('wallpaper-colour-$i')), findsOneWidget);
      }
      await tapKey(t, 'wallpaper-tab-gradient');
      for (var i = 0; i < 6; i++) {
        await reveal(t, byKey('wallpaper-gradient-$i'));
        expect(find.byKey(ValueKey('wallpaper-gradient-$i')), findsOneWidget);
      }
    });

    testWidgets('gradient wallpaper selection', (t) async {
      final photos = FakePhotos();
      await pumpApp(t, photos);
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-gradient');
      await tapKey(t, 'wallpaper-gradient-2');
      final w = look(t).wallpaper;
      expect(w.kind, WallpaperKind.gradient);
      expect(w.colours.length, greaterThanOrEqualTo(2));
      expect(
        paintedColours(byKey('chat-preview')).containsAll(w.colours),
        isTrue,
      );
    });

    testWidgets('picture wallpaper pick success', (t) async {
      final photos = FakePhotos();
      photos.next = const WallpaperPicked(newPath);
      await pumpApp(
        t,
        photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-picture');
      await tapKey(t, 'wallpaper-choose-photo');
      await t.pump(const Duration(milliseconds: 50));
      await t.pumpAndSettle();
      expect(photos.picks, 1);
      final w = look(t).wallpaper;
      expect(w.kind, WallpaperKind.picture);
      expect(w.picturePath, newPath);
      expect(photos.deleted, [oldPath]);
    });

    testWidgets('picture wallpaper pick cancelled', (t) async {
      final photos = FakePhotos();
      photos.next = const WallpaperPickCancelled();
      await pumpApp(
        t,
        photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-picture');
      await tapKey(t, 'wallpaper-choose-photo');
      await t.pump(const Duration(milliseconds: 50));
      await t.pumpAndSettle();
      final w = look(t).wallpaper;
      expect(w.kind, WallpaperKind.picture);
      expect(w.picturePath, oldPath);
      expect(photos.deleted, isEmpty);
      expect(
        find.text('That photo could not be used. Try another.'),
        findsNothing,
      );
    });

    testWidgets('picture wallpaper pick failed', (t) async {
      final photos = FakePhotos();
      photos.next = const WallpaperPickFailed();
      await pumpApp(
        t,
        photos,
        initial: AppearanceSettings(wallpaper: pictureWall),
      );
      await openWallpaper(t);
      await tapKey(t, 'wallpaper-tab-picture');
      await tapKey(t, 'wallpaper-choose-photo');
      await t.pump(const Duration(milliseconds: 50));
      await t.pumpAndSettle();
      final w = look(t).wallpaper;
      expect(w.kind, WallpaperKind.picture);
      expect(w.picturePath, oldPath);
      expect(photos.deleted, isEmpty);
      expect(
        find.text('That photo could not be used. Try another.'),
        findsOneWidget,
      );
      await t.pump(const Duration(seconds: 10)); // let the notice time out
    });

    testWidgets('language specific tab labels', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos,
        initial: AppearanceSettings(language: AppLanguage.tr),
      );
      await openWallpaper(t);
      expect(under('wallpaper-tab-colour', 'Renk'), findsOneWidget);
      expect(under('wallpaper-tab-gradient', 'Gradyan'), findsOneWidget);
      expect(under('wallpaper-tab-picture', 'Resim'), findsOneWidget);
    });

    testWidgets('English tab labels', (t) async {
      final photos = FakePhotos();
      await pumpApp(
        t,
        photos,
        initial: AppearanceSettings(language: AppLanguage.en),
      );
      await openWallpaper(t);
      expect(under('wallpaper-tab-colour', 'Colour'), findsOneWidget);
      expect(under('wallpaper-tab-gradient', 'Gradient'), findsOneWidget);
      expect(under('wallpaper-tab-picture', 'Picture'), findsOneWidget);
    });
  });
}

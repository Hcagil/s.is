import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/appearance/domain/custom_theme.dart';
import 'package:sis/features/appearance/domain/wallpaper.dart';
import 'package:sis/features/appearance/domain/wallpaper_photos.dart';

/// Fakes ---------------------------------------------------------------

class HeldStore implements AppearanceStore {
  HeldStore({this.fail = false});
  final bool fail;
  final saves = <AppearanceSettings>[];
  Completer<void>? gate;
  @override
  Future<AppearanceSettings> load() async => const AppearanceSettings();
  @override
  Future<void> save(AppearanceSettings s) async {
    saves.add(s);
    if (gate != null) await gate!.future;
    if (fail) throw StateError('disk full');
  }
}

class FakePhotos implements WallpaperPhotos {
  WallpaperPick next = const WallpaperPickCancelled();
  final deleted = <String>[];
  int picks = 0;
  Completer<void>? hold;
  @override
  Future<WallpaperPick> pick() async {
    picks++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (hold != null) await hold!.future;
    return next;
  }

  @override
  Future<void> delete(String path) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    deleted.add(path);
  }
}

ProviderContainer containerWith(
  HeldStore store,
  FakePhotos photos, {
  AppearanceSettings? initial,
}) {
  final c = ProviderContainer(
    overrides: [
      appearanceStoreProvider.overrideWithValue(store),
      wallpaperPhotosProvider.overrideWithValue(photos),
      if (initial != null) initialAppearanceProvider.overrideWithValue(initial),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<String> create(
  AppearanceController n,
  String name, {
  CustomThemeMode mode = CustomThemeMode.dark,
}) => n.createCustomTheme(
  name: name,
  mode: mode,
  accent: 0xFF112233,
  mine: 0xFF445566,
  theirs: 0xFF778899,
);

/// Tests ---------------------------------------------------------------

void main() {
  group('createCustomTheme', () {
    test('creates theme with trimmed name and selects it', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, '  Night  ');
      expect(id, isNotEmpty);

      final newState = c.read(appearanceProvider);
      expect(newState.customThemes.length, 1);
      final theme = newState.customThemes.first;
      expect(theme.id, id);
      expect(theme.name, 'Night');
      expect(theme.mode, CustomThemeMode.dark);
      expect(theme.accent, 0xFF112233);
      expect(theme.mine, 0xFF445566);
      expect(theme.theirs, 0xFF778899);
      expect(newState.customThemeId, id);
      expect(newState.activeCustomTheme?.name, 'Night');
      expect(store.saves.last, equals(newState));
    });

    test('second create appends and selects new theme', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id1 = await create(ctrl, 'First');
      final id2 = await create(ctrl, 'Second');
      expect(id1, isNot(id2));

      final state = c.read(appearanceProvider);
      expect(state.customThemes.length, 2);
      expect(state.customThemes[0].id, id1);
      expect(state.customThemes[1].id, id2);
      expect(state.customThemeId, id2);
    });

    test('setTheme clears customThemeId but keeps themes', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      await ctrl.setTheme(AppThemeId.ocean);

      final state = c.read(appearanceProvider);
      expect(state.themeId, AppThemeId.ocean);
      expect(state.customThemeId, isNull);
      expect(state.customThemes.length, 1);
      expect(state.customThemes.first.id, id);
    });
  });

  group('selectCustomTheme', () {
    test('selects existing theme', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      await ctrl.setTheme(AppThemeId.ocean); // deselect
      await ctrl.selectCustomTheme(id);

      final state = c.read(appearanceProvider);
      expect(state.customThemeId, id);
      expect(state.activeCustomTheme?.id, id);
    });

    test('selecting non-existent id does nothing', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await create(ctrl, 'Night');
      final before = c.read(appearanceProvider);
      final beforeSaves = store.saves.length;

      await ctrl.selectCustomTheme('nope');

      final after = c.read(appearanceProvider);
      expect(after, equals(before));
      expect(store.saves.length, beforeSaves);
    });
  });

  group('renameCustomTheme', () {
    test('renames correctly', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      await ctrl.renameCustomTheme(id, 'Dusk');

      final state = c.read(appearanceProvider);
      expect(state.customThemes.first.name, 'Dusk');
      expect(store.saves.last, equals(state));
    });

    test('invalid names leave state unchanged', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      final before = c.read(appearanceProvider);
      final beforeSaves = store.saves.length;

      await ctrl.renameCustomTheme(id, '   ');
      await ctrl.renameCustomTheme(id, '');
      await ctrl.renameCustomTheme('nope', 'X');

      final after = c.read(appearanceProvider);
      expect(after, equals(before));
      expect(store.saves.length, beforeSaves);
    });
  });

  group('duplicateCustomTheme', () {
    test('duplicates with new id and keeps selection', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      final copyId = await ctrl.duplicateCustomTheme(id, 'Copy');

      expect(copyId, isNotNull);
      expect(copyId, isNot(id));

      final state = c.read(appearanceProvider);
      expect(state.customThemes.length, 2);
      final copy = state.customThemes.last;
      expect(copy.id, copyId);
      expect(copy.name, 'Copy');
      expect(copy.mode, CustomThemeMode.dark);
      expect(copy.accent, 0xFF112233);
      expect(copy.mine, 0xFF445566);
      expect(copy.theirs, 0xFF778899);
      expect(state.customThemeId, id);
    });

    test('duplicate with no selection keeps null', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      await ctrl.setTheme(AppThemeId.ocean); // deselect
      final copyId = await ctrl.duplicateCustomTheme(id, 'Copy');

      expect(copyId, isNotNull);
      expect(copyId, isNot(id));

      final state = c.read(appearanceProvider);
      expect(state.customThemeId, isNull);
    });

    test('duplicate with invalid name or id returns null', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      final before = c.read(appearanceProvider);
      final beforeSaves = store.saves.length;

      final res1 = await ctrl.duplicateCustomTheme(id, '');
      final res2 = await ctrl.duplicateCustomTheme('nope', 'X');

      expect(res1, isNull);
      expect(res2, isNull);
      expect(c.read(appearanceProvider), equals(before));
      expect(store.saves.length, beforeSaves);
    });
  });

  group('deleteCustomTheme', () {
    test('deletes selected theme and clears selection', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id = await create(ctrl, 'Night');
      await ctrl.setTheme(AppThemeId.forest); // keep theme
      await ctrl.deleteCustomTheme(id);

      final state = c.read(appearanceProvider);
      expect(state.customThemes, isEmpty);
      expect(state.customThemeId, isNull);
      expect(state.themeId, AppThemeId.forest);
      expect(store.saves.last, equals(state));
    });

    test('deleting non-selected theme keeps selection', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final id1 = await create(ctrl, 'First');
      final id2 = await create(ctrl, 'Second');
      await ctrl.selectCustomTheme(id1);

      await ctrl.deleteCustomTheme(id2);

      final state = c.read(appearanceProvider);
      expect(state.customThemes.length, 1);
      expect(state.customThemes.first.id, id1);
      expect(state.customThemeId, id1);
    });

    test('deleting non-existent id does nothing', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await create(ctrl, 'Night');
      final before = c.read(appearanceProvider);
      final beforeSaves = store.saves.length;

      await ctrl.deleteCustomTheme('nope');

      final after = c.read(appearanceProvider);
      expect(after, equals(before));
      expect(store.saves.length, beforeSaves);
    });
  });

  group('setWallpaper', () {
    test('sets colour wallpaper and saves', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.colour, colours: [0xFF112233]),
      );

      final state = c.read(appearanceProvider);
      expect(state.wallpaper.kind, WallpaperKind.colour);
      expect(state.wallpaper.colours, [0xFF112233]);
      expect(store.saves.last, equals(state));
    });
  });

  group('setWallpaperDim', () {
    test('clamps dim value', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await ctrl.setWallpaperDim(0.5);
      expect(c.read(appearanceProvider).wallpaper.dim, 0.5);

      await ctrl.setWallpaperDim(2.0);
      expect(c.read(appearanceProvider).wallpaper.dim, 0.8);

      await ctrl.setWallpaperDim(-1);
      expect(c.read(appearanceProvider).wallpaper.dim, 0.0);
    });
  });

  group('setWallpaperBlur', () {
    test('clamps blur value', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await ctrl.setWallpaperBlur(6);
      expect(c.read(appearanceProvider).wallpaper.blur, 6);

      await ctrl.setWallpaperBlur(50);
      expect(c.read(appearanceProvider).wallpaper.blur, 12);

      await ctrl.setWallpaperBlur(-3);
      expect(c.read(appearanceProvider).wallpaper.blur, 0);
    });
  });

  group('pickWallpaperPicture', () {
    test('replaces picture and deletes old file', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      // start with old picture
      await ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.picture, picturePath: '/a/old.jpg'),
      );

      photos.next = const WallpaperPicked('/a/new.jpg');
      final pick = await ctrl.pickWallpaperPicture();

      expect(pick, isA<WallpaperPicked>());
      expect(pick, const WallpaperPicked('/a/new.jpg'));
      final state = c.read(appearanceProvider);
      expect(state.wallpaper.kind, WallpaperKind.picture);
      expect(state.wallpaper.picturePath, '/a/new.jpg');
      expect(photos.deleted, ['/a/old.jpg']);
    });

    test('from colour wallpaper deletes nothing', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.colour, colours: [0xFF112233]),
      );

      photos.next = const WallpaperPicked('/a/new.jpg');
      final pick = await ctrl.pickWallpaperPicture();

      expect(pick, isA<WallpaperPicked>());
      expect(pick, const WallpaperPicked('/a/new.jpg'));
      final state = c.read(appearanceProvider);
      expect(state.wallpaper.kind, WallpaperKind.picture);
      expect(state.wallpaper.picturePath, '/a/new.jpg');
      expect(photos.deleted, isEmpty);
    });

    test('cancelled or failed returns same object and no save', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      photos.next = const WallpaperPickCancelled();
      final pick1 = await ctrl.pickWallpaperPicture();
      expect(pick1, isA<WallpaperPickCancelled>());
      expect(c.read(appearanceProvider).wallpaper, Wallpaper.none);
      expect(store.saves, isEmpty); // a load never saves

      photos.next = const WallpaperPickFailed();
      final pick2 = await ctrl.pickWallpaperPicture();
      expect(pick2, isA<WallpaperPickFailed>());
      expect(c.read(appearanceProvider).wallpaper, Wallpaper.none);
      expect(store.saves, isEmpty);
      expect(photos.deleted, isEmpty);
    });

    test('ordering with hold', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      photos.next = const WallpaperPicked('/a/p.jpg');
      photos.hold = Completer();
      final future = ctrl.pickWallpaperPicture();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // state should not change yet
      expect(c.read(appearanceProvider).wallpaper, Wallpaper.none);

      photos.hold!.complete();
      final pick = await future;
      expect(pick, isA<WallpaperPicked>());
      expect(c.read(appearanceProvider).wallpaper.kind, WallpaperKind.picture);
    });
  });

  group('resetWallpaper', () {
    test('resets picture wallpaper and deletes file', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      // create a custom theme to keep
      await create(ctrl, 'Night');

      await ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.picture, picturePath: '/a/old.jpg'),
      );

      await ctrl.resetWallpaper();

      final state = c.read(appearanceProvider);
      expect(state.wallpaper, Wallpaper.none);
      expect(photos.deleted, ['/a/old.jpg']);
      expect(state.customThemes.length, 1);
      expect(store.saves.last, equals(state));
    });

    test('resets colour wallpaper without deletion', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      await ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.colour, colours: [0xFF112233]),
      );

      await ctrl.resetWallpaper();

      final state = c.read(appearanceProvider);
      expect(state.wallpaper, Wallpaper.none);
      expect(photos.deleted, isEmpty);
      expect(store.saves.last, equals(state));
    });
  });

  group('saving never throws and never reverts', () {
    test('create, rename, delete, setWallpaper, setWallpaperDim, resetWallpaper succeed', () async {
      final store = HeldStore(fail: true);
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      final f1 = ctrl.createCustomTheme(
        name: 'Night',
        mode: CustomThemeMode.dark,
        accent: 0xFF112233,
        mine: 0xFF445566,
        theirs: 0xFF778899,
      );
      await expectLater(f1, completes);

      final id = c.read(appearanceProvider).customThemes.first.id;

      final f2 = ctrl.renameCustomTheme(id, 'Dusk');
      await expectLater(f2, completes);
      expect(c.read(appearanceProvider).customThemes.single.name, 'Dusk');

      final f3 = ctrl.deleteCustomTheme(id);
      await expectLater(f3, completes);
      expect(c.read(appearanceProvider).customThemes, isEmpty);

      final f4 = ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.colour, colours: [0xFF112233]),
      );
      await expectLater(f4, completes);

      final f5 = ctrl.setWallpaperDim(0.5);
      await expectLater(f5, completes);
      expect(c.read(appearanceProvider).wallpaper.dim, 0.5);

      final f6 = ctrl.resetWallpaper();
      await expectLater(f6, completes);
      expect(c.read(appearanceProvider).wallpaper, Wallpaper.none);
    });

    test('state changes before gate completes', () async {
      final store = HeldStore();
      final photos = FakePhotos();
      final c = containerWith(store, photos);
      final ctrl = c.read(appearanceProvider.notifier);

      store.gate = Completer();

      final future = ctrl.setWallpaper(
        const Wallpaper(kind: WallpaperKind.colour, colours: [0xFF112233]),
      );

      // state should be updated immediately
      expect(c.read(appearanceProvider).wallpaper.kind, WallpaperKind.colour);

      // but save is pending
      expect(store.saves.length, 1); // the save has started and is held
      store.gate!.complete();
      await future;
      expect(c.read(appearanceProvider).wallpaper.kind, WallpaperKind.colour);
    });
  });
}

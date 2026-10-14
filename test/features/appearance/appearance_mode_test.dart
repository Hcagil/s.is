// This test file is written from the contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';

void main() {
  group('AppearanceMode domain', () {
    test('enum names are ["system","light","dark"]', () {
      final names = AppearanceMode.values.map((e) => e.name).toList();
      expect(names, ['system', 'light', 'dark']);
    });

    test('default mode is system', () {
      expect(const AppearanceSettings().mode, AppearanceMode.system);
    });

    test('copyWith changes only mode', () {
      const original = AppearanceSettings();
      const darkSettings = AppearanceSettings(mode: AppearanceMode.dark);
      expect(original.copyWith(mode: AppearanceMode.dark), darkSettings);
    });

    test('settings differing only by mode are not equal', () {
      const a = AppearanceSettings(mode: AppearanceMode.system);
      const b = AppearanceSettings(mode: AppearanceMode.light);
      expect(a == b, isFalse);
    });

    test('equal settings have equal hashCode', () {
      const a = AppearanceSettings(mode: AppearanceMode.system);
      const b = AppearanceSettings(mode: AppearanceMode.system);
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('SharedPrefsAppearanceStore', () {
    const store = SharedPrefsAppearanceStore();

    test('nothing stored loads the defaults', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await store.load(), const AppearanceSettings());
    });

    test('save light then load gives light and raw prefs', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(const AppearanceSettings(mode: AppearanceMode.light));
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.light);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sis.appearance.mode'), 'light');
    });

    test('save dark then load gives dark and raw prefs', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(const AppearanceSettings(mode: AppearanceMode.dark));
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.dark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sis.appearance.mode'), 'dark');
    });

    test('pre-set dark loads as dark', () async {
      SharedPreferences.setMockInitialValues({'sis.appearance.mode': 'dark'});
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.dark);
    });

    test('missing key loads system', () async {
      SharedPreferences.setMockInitialValues({});
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.system);
    });

    test('unknown string loads system', () async {
      SharedPreferences.setMockInitialValues({'sis.appearance.mode': 'dim'});
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.system);
    });

    test('int value loads system', () async {
      SharedPreferences.setMockInitialValues({'sis.appearance.mode': 1});
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.system);
    });

    test('save dark then save system results in system', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(const AppearanceSettings(mode: AppearanceMode.dark));
      await store.save(const AppearanceSettings(mode: AppearanceMode.system));
      final loaded = await store.load();
      expect(loaded.mode, AppearanceMode.system);
    });
  });
}

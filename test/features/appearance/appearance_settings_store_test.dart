// The appearance settings value and its per-device store, written from the
// contract. The store runs over the real SharedPreferences plugin API (its
// in-memory platform), not a mock of it.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';

const keys = (
  theme: 'sis.appearance.theme',
  font: 'sis.appearance.system_font',
  chat: 'sis.appearance.chat_size',
  app: 'sis.appearance.app_size',
  language: 'sis.appearance.language',
);

const custom = AppearanceSettings(
  themeId: AppThemeId.ocean,
  systemFont: false,
  chatTextSize: TextSize.large,
  appTextSize: TextSize.small,
  language: AppLanguage.tr,
);

void main() {
  group('AppearanceSettings', () {
    test('the six themes, three sizes and three languages', () {
      expect(AppThemeId.values.map((e) => e.name), [
        'violet',
        'ocean',
        'forest',
        'sunset',
        'graphite',
        'rose',
      ]);
      expect(TextSize.small.scale, 0.88);
      expect(TextSize.medium.scale, 1.0);
      expect(TextSize.large.scale, 1.2);
      expect(AppLanguage.values.map((e) => e.name), ['system', 'en', 'tr']);
    });

    test('defaults', () {
      const d = AppearanceSettings();
      expect(d.themeId, AppThemeId.violet);
      expect(d.systemFont, isTrue);
      expect(d.chatTextSize, TextSize.medium);
      expect(d.appTextSize, TextSize.medium);
      expect(d.language, AppLanguage.system);
    });

    test('value equality on every field', () {
      expect(custom, custom.copyWith());
      expect(custom.hashCode, custom.copyWith().hashCode);
      expect(const AppearanceSettings(), isNot(custom));
      for (final other in [
        custom.copyWith(themeId: AppThemeId.rose),
        custom.copyWith(systemFont: true),
        custom.copyWith(chatTextSize: TextSize.medium),
        custom.copyWith(appTextSize: TextSize.medium),
        custom.copyWith(language: AppLanguage.en),
      ]) {
        expect(other, isNot(custom));
      }
    });

    test('copyWith changes only what it is given', () {
      const d = AppearanceSettings();
      expect(
        d.copyWith(themeId: AppThemeId.ocean),
        const AppearanceSettings(themeId: AppThemeId.ocean),
      );
      expect(
        d.copyWith(systemFont: false),
        const AppearanceSettings(systemFont: false),
      );
      expect(
        d.copyWith(chatTextSize: TextSize.large),
        const AppearanceSettings(chatTextSize: TextSize.large),
      );
      expect(
        d.copyWith(appTextSize: TextSize.small),
        const AppearanceSettings(appTextSize: TextSize.small),
      );
      expect(
        d.copyWith(language: AppLanguage.tr),
        const AppearanceSettings(language: AppLanguage.tr),
      );
    });
  });

  group('SharedPrefsAppearanceStore', () {
    const store = SharedPrefsAppearanceStore();

    test('nothing stored loads the defaults', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await store.load(), const AppearanceSettings());
    });

    test('round trip, enums stored by name under the device keys', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(custom);
      expect(await store.load(), custom);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.get(keys.theme), 'ocean');
      expect(prefs.get(keys.chat), 'large');
      expect(prefs.get(keys.app), 'small');
      expect(prefs.get(keys.language), 'tr');
      expect(prefs.containsKey(keys.font), isTrue);
    });

    test('a second save overwrites the first', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(custom);
      await store.save(const AppearanceSettings());
      expect(await store.load(), const AppearanceSettings());
    });

    test('reads what an earlier run stored', () async {
      SharedPreferences.setMockInitialValues({
        keys.theme: 'graphite',
        keys.font: false,
        keys.chat: 'small',
        keys.app: 'large',
        keys.language: 'en',
      });
      expect(
        await store.load(),
        const AppearanceSettings(
          themeId: AppThemeId.graphite,
          systemFont: false,
          chatTextSize: TextSize.small,
          appTextSize: TextSize.large,
          language: AppLanguage.en,
        ),
      );
    });

    test('an unknown name falls back to that field\'s default', () async {
      SharedPreferences.setMockInitialValues({
        keys.theme: 'neon',
        keys.chat: 'huge',
        keys.app: '',
        keys.language: 'de',
      });
      final s = await store.load();
      expect(s.themeId, AppThemeId.violet);
      expect(s.chatTextSize, TextSize.medium);
      expect(s.appTextSize, TextSize.medium);
      expect(s.language, AppLanguage.system);
    });

    test('values of the wrong type load the defaults, never throw', () async {
      SharedPreferences.setMockInitialValues({
        keys.theme: 7,
        keys.font: 'yes',
        keys.chat: true,
        keys.app: 1.5,
        keys.language: <String>['tr'],
      });
      expect(await store.load(), const AppearanceSettings());
    });
  });
}

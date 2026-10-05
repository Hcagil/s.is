import 'package:shared_preferences/shared_preferences.dart';

import '../domain/appearance_settings.dart';

/// [AppearanceStore] over shared_preferences: per device, never synced.
final class SharedPrefsAppearanceStore implements AppearanceStore {
  const SharedPrefsAppearanceStore();

  static const _themeKey = 'sis.appearance.theme';
  static const _systemFontKey = 'sis.appearance.system_font';
  static const _chatSizeKey = 'sis.appearance.chat_size';
  static const _appSizeKey = 'sis.appearance.app_size';
  static const _languageKey = 'sis.appearance.language';

  @override
  Future<AppearanceSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const d = AppearanceSettings();
      return AppearanceSettings(
        themeId:
            AppThemeId.values.asNameMap()[prefs.getString(_themeKey)] ??
            d.themeId,
        systemFont: prefs.getBool(_systemFontKey) ?? d.systemFont,
        chatTextSize:
            TextSize.values.asNameMap()[prefs.getString(_chatSizeKey)] ??
            d.chatTextSize,
        appTextSize:
            TextSize.values.asNameMap()[prefs.getString(_appSizeKey)] ??
            d.appTextSize,
        language:
            AppLanguage.values.asNameMap()[prefs.getString(_languageKey)] ??
            d.language,
      );
    } catch (_) {
      return const AppearanceSettings();
    }
  }

  @override
  Future<void> save(AppearanceSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, settings.themeId.name);
    await prefs.setBool(_systemFontKey, settings.systemFont);
    await prefs.setString(_chatSizeKey, settings.chatTextSize.name);
    await prefs.setString(_appSizeKey, settings.appTextSize.name);
    await prefs.setString(_languageKey, settings.language.name);
  }
}

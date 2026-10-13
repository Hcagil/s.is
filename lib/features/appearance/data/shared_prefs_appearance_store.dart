import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/appearance_settings.dart';
import '../domain/custom_theme.dart';
import '../domain/wallpaper.dart';

/// [AppearanceStore] over shared_preferences: per device, never synced.
final class SharedPrefsAppearanceStore implements AppearanceStore {
  const SharedPrefsAppearanceStore();

  static const _themeKey = 'sis.appearance.theme';
  static const _systemFontKey = 'sis.appearance.system_font';
  static const _chatSizeKey = 'sis.appearance.chat_size';
  static const _appSizeKey = 'sis.appearance.app_size';
  static const _languageKey = 'sis.appearance.language';
  static const _customThemesKey = 'sis.appearance.custom_themes';
  static const _customThemeIdKey = 'sis.appearance.custom_theme_id';
  static const _wallpaperKey = 'sis.appearance.wallpaper';

  @override
  Future<AppearanceSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const d = AppearanceSettings();
      final customThemes = _themes(prefs.getString(_customThemesKey));
      var customThemeId = prefs.getString(_customThemeIdKey);
      if (customThemeId != null &&
          !customThemes.any((t) => t.id == customThemeId)) {
        customThemeId = null;
      }
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
        customThemes: customThemes,
        customThemeId: customThemeId,
        wallpaper: _wallpaper(prefs.getString(_wallpaperKey)),
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
    if (settings.customThemes.isNotEmpty) {
      await prefs.setString(
        _customThemesKey,
        jsonEncode(settings.customThemes.map((t) => t.toJson()).toList()),
      );
    } else {
      await prefs.remove(_customThemesKey);
    }
    final selected = settings.customThemeId;
    if (selected != null) {
      await prefs.setString(_customThemeIdKey, selected);
    } else {
      await prefs.remove(_customThemeIdKey);
    }
    await prefs.setString(
      _wallpaperKey,
      jsonEncode(settings.wallpaper.toJson()),
    );
  }

  static List<CustomTheme> _themes(String? raw) {
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .map((e) => CustomTheme.tryFromJson(e))
          .whereType<CustomTheme>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Wallpaper _wallpaper(String? raw) {
    if (raw == null) return Wallpaper.none;
    try {
      return Wallpaper.tryFromJson(jsonDecode(raw));
    } catch (_) {
      return Wallpaper.none;
    }
  }
}

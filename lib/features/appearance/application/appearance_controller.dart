import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/appearance_settings.dart';

/// Where the settings are saved on this phone (shared_preferences in data/).
final appearanceStoreProvider = Provider<AppearanceStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// The settings read before runApp, so the first frame is already right.
final initialAppearanceProvider = Provider<AppearanceSettings>(
  (_) => const AppearanceSettings(),
);

final appearanceProvider =
    NotifierProvider<AppearanceController, AppearanceSettings>(
      AppearanceController.new,
    );

/// The current theme, font, text sizes and language. Each change shows at
/// once and is then saved; a failed save never throws or reverts the screen.
class AppearanceController extends Notifier<AppearanceSettings> {
  @override
  AppearanceSettings build() => ref.read(initialAppearanceProvider);

  /// Sets the theme.
  Future<void> setTheme(AppThemeId themeId) =>
      _update(state.copyWith(themeId: themeId));

  /// Sets whether the phone's own font is used (off: SIS's own font).
  Future<void> setSystemFont(bool systemFont) =>
      _update(state.copyWith(systemFont: systemFont));

  /// Sets the chat text size.
  Future<void> setChatTextSize(TextSize chatTextSize) =>
      _update(state.copyWith(chatTextSize: chatTextSize));

  /// Sets the app text size.
  Future<void> setAppTextSize(TextSize appTextSize) =>
      _update(state.copyWith(appTextSize: appTextSize));

  /// Sets the language.
  Future<void> setLanguage(AppLanguage language) =>
      _update(state.copyWith(language: language));

  Future<void> _update(AppearanceSettings next) async {
    state = next;
    try {
      await ref.read(appearanceStoreProvider).save(next);
    } catch (e) {
      log('Saving appearance failed: ${e.runtimeType}', name: 'sis.appearance');
    }
  }
}

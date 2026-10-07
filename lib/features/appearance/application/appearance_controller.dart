import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/appearance_settings.dart';
import '../domain/custom_theme.dart';
import '../domain/wallpaper.dart';
import '../domain/wallpaper_photos.dart';

/// Where the settings are saved on this phone (shared_preferences in data/).
final appearanceStoreProvider = Provider<AppearanceStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// The settings read before runApp, so the first frame is already right.
final initialAppearanceProvider = Provider<AppearanceSettings>(
  (_) => const AppearanceSettings(),
);

/// Chooses a wallpaper photo and keeps a copy in the app's own folder.
final wallpaperPhotosProvider = Provider<WallpaperPhotos>(
  (_) => throw UnimplementedError('override in main'),
);

final appearanceProvider =
    NotifierProvider<AppearanceController, AppearanceSettings>(
      AppearanceController.new,
    );

/// The current theme, font, text sizes, language, custom themes and
/// wallpaper. Each change shows at once and is then saved; a failed save never
/// throws or reverts the screen.
class AppearanceController extends Notifier<AppearanceSettings> {
  @override
  AppearanceSettings build() => ref.read(initialAppearanceProvider);

  /// Sets a built-in theme (clears a custom choice).
  Future<void> setTheme(AppThemeId themeId) =>
      _update(state.copyWith(themeId: themeId, customThemeId: null));

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

  /// Makes a custom theme, selects it and returns its id.
  Future<String> createCustomTheme({
    required String name,
    required CustomThemeMode mode,
    required int accent,
    required int mine,
    required int theirs,
  }) async {
    final id = _freshId();
    final theme = CustomTheme(
      id: id,
      name: name.trim(),
      mode: mode,
      accent: accent,
      mine: mine,
      theirs: theirs,
    );
    await _update(
      state.copyWith(
        customThemes: [...state.customThemes, theme],
        customThemeId: id,
      ),
    );
    return id;
  }

  /// Selects the custom theme [id]; an unknown id changes nothing.
  Future<void> selectCustomTheme(String id) async {
    if (!state.customThemes.any((t) => t.id == id)) return;
    await _update(state.copyWith(customThemeId: id));
  }

  /// Renames a custom theme; an empty name or unknown id changes nothing.
  Future<void> renameCustomTheme(String id, String name) async {
    final trimmed = name.trim();
    final index = state.customThemes.indexWhere((t) => t.id == id);
    if (trimmed.isEmpty || index < 0) return;
    await _update(
      state.copyWith(
        customThemes: List.of(state.customThemes)
          ..[index] = state.customThemes[index].copyWith(name: trimmed),
      ),
    );
  }

  /// Copies a custom theme under [name] (added last, selection unchanged) and
  /// returns the copy's id; null for an empty name or unknown id.
  Future<String?> duplicateCustomTheme(String id, String name) async {
    final trimmed = name.trim();
    final index = state.customThemes.indexWhere((t) => t.id == id);
    if (trimmed.isEmpty || index < 0) return null;
    final copy = state.customThemes[index].copyWith(
      id: _freshId(),
      name: trimmed,
    );
    await _update(state.copyWith(customThemes: [...state.customThemes, copy]));
    return copy.id;
  }

  /// Deletes a custom theme; if it was chosen, the built-in theme chosen
  /// before applies again.
  Future<void> deleteCustomTheme(String id) async {
    if (!state.customThemes.any((t) => t.id == id)) return;
    await _update(
      state.copyWith(
        customThemes: [
          for (final t in state.customThemes)
            if (t.id != id) t,
        ],
        customThemeId: state.customThemeId == id ? null : state.customThemeId,
      ),
    );
  }

  /// Sets the wallpaper.
  Future<void> setWallpaper(Wallpaper wallpaper) =>
      _update(state.copyWith(wallpaper: wallpaper));

  /// Removes the wallpaper (the theme's own applies again) and deletes the
  /// picked picture file.
  Future<void> resetWallpaper() async {
    final old = state.wallpaper.picturePath;
    await _update(state.copyWith(wallpaper: Wallpaper.none));
    if (old != null) await ref.read(wallpaperPhotosProvider).delete(old);
  }

  /// Sets how much the picture wallpaper is darkened (0 to 0.8).
  Future<void> setWallpaperDim(double dim) => _update(
    state.copyWith(
      wallpaper: state.wallpaper.copyWith(dim: dim.clamp(0.0, 0.8).toDouble()),
    ),
  );

  /// Sets how much the picture wallpaper is blurred (0 to 12).
  Future<void> setWallpaperBlur(double blur) => _update(
    state.copyWith(
      wallpaper: state.wallpaper.copyWith(
        blur: blur.clamp(0.0, 12.0).toDouble(),
      ),
    ),
  );

  /// Opens the photo chooser; a picked photo becomes the wallpaper and the
  /// previous picture file is deleted. Returns what happened.
  Future<WallpaperPick> pickWallpaperPicture() async {
    final photos = ref.read(wallpaperPhotosProvider);
    final result = await photos.pick();
    if (result is WallpaperPicked) {
      final old = state.wallpaper.picturePath;
      await _update(
        state.copyWith(
          wallpaper: state.wallpaper.copyWith(
            kind: WallpaperKind.picture,
            picturePath: result.path,
          ),
        ),
      );
      if (old != null && old != result.path) await photos.delete(old);
    }
    return result;
  }

  Future<void> _update(AppearanceSettings next) async {
    state = next;
    try {
      await ref.read(appearanceStoreProvider).save(next);
    } catch (e) {
      log('Saving appearance failed: ${e.runtimeType}', name: 'sis.appearance');
    }
  }

  /// A new theme id, unique among the themes on this phone.
  String _freshId() {
    var n = DateTime.now().microsecondsSinceEpoch;
    while (state.customThemes.any((t) => t.id == '$n')) {
      n++;
    }
    return '$n';
  }
}

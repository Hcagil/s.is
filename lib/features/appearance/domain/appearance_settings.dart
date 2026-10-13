import 'custom_theme.dart';
import 'wallpaper.dart';

/// Theme, font, text size, and language choices. Stored on the phone only;
/// see AppearanceStore.
enum AppThemeId { violet, ocean, forest, sunset, graphite, rose }

/// Text size multipliers for chat messages and app UI.
enum TextSize {
  small(0.88),
  medium(1.0),
  large(1.2);

  const TextSize(this.scale);
  final double scale;
}

/// Language choice; system means the phone's current language.
enum AppLanguage { system, en, tr }

const _keep = Object();

/// The member's appearance choices.
final class AppearanceSettings {
  const AppearanceSettings({
    this.themeId = AppThemeId.violet,
    this.systemFont = true,
    this.chatTextSize = TextSize.medium,
    this.appTextSize = TextSize.medium,
    this.language = AppLanguage.system,
    this.customThemes = const <CustomTheme>[],
    this.customThemeId,
    this.wallpaper = Wallpaper.none,
  });

  final AppThemeId themeId;
  final bool systemFont;
  final TextSize chatTextSize;
  final TextSize appTextSize;
  final AppLanguage language;

  /// The member's own themes, in the order made.
  final List<CustomTheme> customThemes;

  /// The chosen custom theme's id; null when a built-in theme is chosen.
  final String? customThemeId;

  /// The member's own wallpaper; none means the theme's own look.
  final Wallpaper wallpaper;

  AppearanceSettings copyWith({
    AppThemeId? themeId,
    bool? systemFont,
    TextSize? chatTextSize,
    TextSize? appTextSize,
    AppLanguage? language,
    List<CustomTheme>? customThemes,
    Object? customThemeId = _keep,
    Wallpaper? wallpaper,
  }) {
    return AppearanceSettings(
      themeId: themeId ?? this.themeId,
      systemFont: systemFont ?? this.systemFont,
      chatTextSize: chatTextSize ?? this.chatTextSize,
      appTextSize: appTextSize ?? this.appTextSize,
      language: language ?? this.language,
      customThemes: customThemes ?? this.customThemes,
      customThemeId: identical(customThemeId, _keep)
          ? this.customThemeId
          : customThemeId as String?,
      wallpaper: wallpaper ?? this.wallpaper,
    );
  }

  /// The chosen custom theme; null when none is chosen or its id is unknown.
  CustomTheme? get activeCustomTheme {
    if (customThemeId == null) return null;
    for (final theme in customThemes) {
      if (theme.id == customThemeId) return theme;
    }
    return null;
  }

  /// What the chat paints: the member's own wallpaper wins; otherwise a custom
  /// theme's chat colour (none when it has no colour), else a built-in theme's
  /// own (dark mode only).
  Wallpaper effectiveWallpaper({required bool dark}) {
    if (wallpaper.kind != WallpaperKind.none) return wallpaper;
    final custom = activeCustomTheme;
    if (custom != null) {
      final bg = custom.background;
      return bg == null
          ? Wallpaper.none
          : Wallpaper(kind: WallpaperKind.colour, colours: [bg]);
    }
    if (!dark) return Wallpaper.none;
    return builtInWallpaper(themeId);
  }

  @override
  bool operator ==(Object other) =>
      other is AppearanceSettings &&
      other.themeId == themeId &&
      other.systemFont == systemFont &&
      other.chatTextSize == chatTextSize &&
      other.appTextSize == appTextSize &&
      other.language == language &&
      _sameThemes(other.customThemes, customThemes) &&
      other.customThemeId == customThemeId &&
      other.wallpaper == wallpaper;

  @override
  int get hashCode => Object.hash(
    themeId,
    systemFont,
    chatTextSize,
    appTextSize,
    language,
    Object.hashAll(customThemes),
    customThemeId,
    wallpaper,
  );
}

bool _sameThemes(List<CustomTheme> a, List<CustomTheme> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The phone-only store of the appearance settings.
abstract interface class AppearanceStore {
  /// Never throws: a missing or unreadable store gives the defaults.
  Future<AppearanceSettings> load();

  Future<void> save(AppearanceSettings settings);
}

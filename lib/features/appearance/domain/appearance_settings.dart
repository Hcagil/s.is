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

/// The member's appearance choices.
final class AppearanceSettings {
  const AppearanceSettings({
    this.themeId = AppThemeId.violet,
    this.systemFont = true,
    this.chatTextSize = TextSize.medium,
    this.appTextSize = TextSize.medium,
    this.language = AppLanguage.system,
  });

  final AppThemeId themeId;
  final bool systemFont;
  final TextSize chatTextSize;
  final TextSize appTextSize;
  final AppLanguage language;

  AppearanceSettings copyWith({
    AppThemeId? themeId,
    bool? systemFont,
    TextSize? chatTextSize,
    TextSize? appTextSize,
    AppLanguage? language,
  }) {
    return AppearanceSettings(
      themeId: themeId ?? this.themeId,
      systemFont: systemFont ?? this.systemFont,
      chatTextSize: chatTextSize ?? this.chatTextSize,
      appTextSize: appTextSize ?? this.appTextSize,
      language: language ?? this.language,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppearanceSettings &&
      other.themeId == themeId &&
      other.systemFont == systemFont &&
      other.chatTextSize == chatTextSize &&
      other.appTextSize == appTextSize &&
      other.language == language;

  @override
  int get hashCode =>
      Object.hash(themeId, systemFont, chatTextSize, appTextSize, language);
}

/// The phone-only store of the appearance settings.
abstract interface class AppearanceStore {
  /// Never throws: a missing or unreadable store gives the defaults.
  Future<AppearanceSettings> load();

  Future<void> save(AppearanceSettings settings);
}

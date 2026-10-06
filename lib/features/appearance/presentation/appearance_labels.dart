import '../../../l10n/app_localizations.dart';
import '../domain/appearance_settings.dart';

String themeLabel(AppLocalizations l, AppThemeId id) {
  switch (id) {
    case AppThemeId.violet:
      return l.themeViolet;
    case AppThemeId.ocean:
      return l.themeOcean;
    case AppThemeId.forest:
      return l.themeForest;
    case AppThemeId.sunset:
      return l.themeSunset;
    case AppThemeId.graphite:
      return l.themeGraphite;
    case AppThemeId.rose:
      return l.themeRose;
  }
}

String textSizeLabel(AppLocalizations l, TextSize s) {
  switch (s) {
    case TextSize.small:
      return l.textSmall;
    case TextSize.medium:
      return l.textMedium;
    case TextSize.large:
      return l.textLarge;
  }
}

String languageLabel(AppLocalizations l, AppLanguage v) {
  switch (v) {
    case AppLanguage.system:
      return l.languageSystem;
    case AppLanguage.en:
      return l.languageEnglish;
    case AppLanguage.tr:
      return l.languageTurkish;
  }
}

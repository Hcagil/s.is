// Localisation for tests: the strings production reads, and the delegates a
// bare MaterialApp needs before any screen can call AppLocalizations.of.
import 'package:flutter/material.dart';
import 'package:sis/l10n/app_localizations.dart';

final l10nEn = lookupAppLocalizations(const Locale('en'));
final l10nTr = lookupAppLocalizations(const Locale('tr'));

/// A MaterialApp wired for localisation as SisApp wires it.
MaterialApp localizedApp({
  Widget? home,
  Locale locale = const Locale('en'),
  ThemeData? theme,
  GlobalKey<NavigatorState>? navigatorKey,
  Map<String, WidgetBuilder> routes = const {},
}) => MaterialApp(
  home: home,
  locale: locale,
  theme: theme,
  navigatorKey: navigatorKey,
  routes: routes,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
);

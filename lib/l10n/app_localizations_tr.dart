// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Turkish (`tr`).
class AppLocalizationsTr extends AppLocalizations {
  AppLocalizationsTr([String locale = 'tr']) : super(locale);

  @override
  String get deliverySending => 'Gönderiliyor';

  @override
  String get deliverySent => 'Gönderildi';

  @override
  String get deliveryDelivered => 'Teslim edildi';

  @override
  String get deliveryRead => 'Okundu';
}

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get deliverySending => 'Sending';

  @override
  String get deliverySent => 'Sent';

  @override
  String get deliveryDelivered => 'Delivered';

  @override
  String get deliveryRead => 'Read';
}

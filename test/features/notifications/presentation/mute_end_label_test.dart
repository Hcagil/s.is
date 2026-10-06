// muteEndLabel: the words for when a mute ends, in English and Turkish, from
// the contract. Run under TZ=JST-9 as CI does; the time shown is local.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sis/features/notifications/presentation/notification_pages.dart';

import '../../../support/l10n.dart';

/// The UTC instant whose JST (UTC+9) clock reads (y, m, d, h:min).
DateTime jst(int y, int m, int d, int h, [int min = 0]) =>
    DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 9));

void main() {
  // In the app the Material localisation delegates load the date symbols;
  // calling muteEndLabel outside a widget tree needs them loaded by hand.
  setUpAll(initializeDateFormatting);

  final cases = <(String, DateTime?, DateTime, String, String)>[
    ('no end', null, DateTime.utc(2026, 9, 24), 'Always', 'Süresiz'),
    (
      'same local day',
      jst(2026, 9, 24, 18, 5),
      jst(2026, 9, 24, 8),
      'Until 18:05',
      '18:05 saatine kadar',
    ),
    (
      'zero-padded',
      jst(2026, 9, 24, 5, 3),
      jst(2026, 9, 24, 0),
      'Until 05:03',
      '05:03 saatine kadar',
    ),
    (
      'next local day',
      jst(2026, 9, 25, 9),
      jst(2026, 9, 24, 23),
      'Until tomorrow 09:00',
      'Yarın 09:00 saatine kadar',
    ),
    (
      'later day',
      jst(2026, 10, 3, 18, 5),
      jst(2026, 9, 24, 9),
      'Until Oct 3 18:05',
      '3 Eki 18:05 saatine kadar',
    ),
    (
      'UTC boundary, same local day',
      DateTime.utc(2026, 9, 25, 1),
      DateTime.utc(2026, 9, 24, 23),
      'Until 10:00',
      '10:00 saatine kadar',
    ),
    (
      'one UTC day, next local day',
      DateTime.utc(2026, 9, 30, 16),
      DateTime.utc(2026, 9, 30, 14),
      'Until tomorrow 01:00',
      'Yarın 01:00 saatine kadar',
    ),
  ];

  for (final (name, until, now, en, tr) in cases) {
    test('$name: en "$en", tr "$tr"', () {
      expect(muteEndLabel(l10nEn, until, now), en);
      expect(muteEndLabel(l10nTr, until, now), tr);
    });
  }
}

// Day chip and read-time labels, from the contract only. Run under TZ=JST-9 too.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sis/features/chat/presentation/day_chip.dart';
import 'package:sis/features/chat/presentation/seen_time.dart';
import 'package:sis/l10n/app_localizations.dart';

late AppLocalizations en, tr;

String two(int n) => n.toString().padLeft(2, '0');

void main() {
  // The app gets intl's date data from GlobalMaterialLocalizations; here, directly.
  setUpAll(initializeDateFormatting);
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    tr = await AppLocalizations.delegate.load(const Locale('tr'));
  });

  group('dayChipLabel', () {
    test('same local day: today', () {
      final now = DateTime(2026, 10, 18, 12, 0);
      final at1 = DateTime(2026, 10, 18, 0, 0);
      final at2 = DateTime(2026, 10, 18, 23, 59);
      expect(
        dayChipLabel(en, at1, now),
        'Today',
        reason: 'at midnight same day',
      );
      expect(
        dayChipLabel(en, at2, now),
        'Today',
        reason: 'at end of day same day',
      );
      expect(dayChipLabel(tr, at1, now), 'Bugün', reason: 'Turkish today');
    });

    test('midnight boundary: previous day', () {
      final now = DateTime(2026, 10, 18, 0, 1);
      final at = DateTime(2026, 10, 17, 23, 59);
      expect(
        dayChipLabel(en, at, now),
        'October 17',
        reason: 'previous day label',
      );
      expect(
        dayChipLabel(tr, at, now),
        '17 Ekim',
        reason: 'Turkish previous day',
      );
    });

    test('midnight boundary: same day after midnight', () {
      final now = DateTime(2026, 10, 18, 23, 59);
      final at = DateTime(2026, 10, 18, 0, 1);
      expect(
        dayChipLabel(en, at, now),
        'Today',
        reason: 'same day after midnight',
      );
    });

    test('other days same year', () {
      final now = DateTime(2026, 10, 18, 12, 0);
      final at = DateTime(2026, 10, 16, 12, 0);
      expect(
        dayChipLabel(en, at, now),
        'October 16',
        reason: 'other day same year',
      );
      expect(
        dayChipLabel(tr, at, now),
        '16 Ekim',
        reason: 'Turkish other day same year',
      );
    });

    test('other year', () {
      final now = DateTime(2026, 10, 18, 12, 0);
      final at = DateTime(2025, 10, 16, 12, 0);
      expect(
        dayChipLabel(en, at, now),
        'October 16, 2025',
        reason: 'other year',
      );
      expect(
        dayChipLabel(tr, at, now),
        '16 Ekim 2025',
        reason: 'Turkish other year',
      );
    });

    test('year boundary', () {
      final now = DateTime(2026, 1, 1, 0, 1);
      final at = DateTime(2025, 12, 31, 23, 59);
      expect(
        dayChipLabel(en, at, now),
        'December 31, 2025',
        reason: 'year boundary',
      );
      expect(
        dayChipLabel(tr, at, now),
        '31 Aralık 2025',
        reason: 'Turkish year boundary',
      );
    });

    test('different month same year', () {
      final now = DateTime(2026, 10, 18, 12, 0);
      final at = DateTime(2026, 1, 5, 12, 0);
      expect(
        dayChipLabel(en, at, now),
        'January 5',
        reason: 'different month same year',
      );
      expect(
        dayChipLabel(tr, at, now),
        '5 Ocak',
        reason: 'Turkish different month same year',
      );
    });
  });

  group('seenTime', () {
    test('today same day', () {
      final now = DateTime(2026, 10, 18, 15, 0);
      final at1 = DateTime(2026, 10, 18, 14, 32);
      final at2 = DateTime(2026, 10, 18, 9, 5);
      expect(seenTime(en, at1, now), '14:32', reason: 'today time');
      expect(seenTime(en, at2, now), '09:05', reason: 'today padded time');
      expect(seenTime(tr, at1, now), '14:32', reason: 'Turkish today time');
    });

    test('midnight boundary yesterday', () {
      final now = DateTime(2026, 10, 18, 0, 1);
      final at = DateTime(2026, 10, 17, 23, 59);
      expect(
        seenTime(en, at, now),
        'yesterday at 23:59',
        reason: 'yesterday midnight',
      );
      expect(
        seenTime(tr, at, now),
        'dün 23:59',
        reason: 'Turkish yesterday midnight',
      );
    });

    test('yesterday across month', () {
      final now = DateTime(2026, 11, 1, 10, 0);
      final at = DateTime(2026, 10, 31, 14, 32);
      expect(
        seenTime(en, at, now),
        'yesterday at 14:32',
        reason: 'yesterday across month',
      );
      expect(
        seenTime(tr, at, now),
        'dün 14:32',
        reason: 'Turkish yesterday across month',
      );
    });

    test('yesterday across year', () {
      final now = DateTime(2026, 1, 1, 0, 30);
      final at = DateTime(2025, 12, 31, 22, 15);
      expect(
        seenTime(en, at, now),
        'yesterday at 22:15',
        reason: 'yesterday across year',
      );
      expect(
        seenTime(tr, at, now),
        'dün 22:15',
        reason: 'Turkish yesterday across year',
      );
    });

    test('two days ago within year', () {
      final now = DateTime(2026, 10, 18, 15, 0);
      final at = DateTime(2026, 10, 16, 14, 32);
      expect(seenTime(en, at, now), 'Oct 16 at 14:32', reason: 'two days ago');
      expect(
        seenTime(tr, at, now),
        '16 Eki 14:32',
        reason: 'Turkish two days ago',
      );
    });

    test('364 days ago within year', () {
      final now = DateTime(2026, 10, 18, 15, 0);
      final at = DateTime(2025, 10, 19, 15, 0);
      expect(seenTime(en, at, now), 'Oct 19 at 15:00', reason: '364 days ago');
      expect(
        seenTime(tr, at, now),
        '19 Eki 15:00',
        reason: 'Turkish 364 days ago',
      );
    });

    test('365 days ago older', () {
      final now = DateTime(2026, 10, 18, 15, 0);
      final at = DateTime(2025, 10, 18, 15, 0);
      expect(
        seenTime(en, at, now),
        '18.10.25 at 15:00',
        reason: '365 days ago',
      );
      expect(
        seenTime(tr, at, now),
        '18.10.25 15:00',
        reason: 'Turkish 365 days ago',
      );
    });

    test('3 years ago older', () {
      final at = DateTime(2024, 10, 16, 14, 32);
      final now = DateTime(2026, 10, 18, 15, 0);
      expect(seenTime(en, at, now), '16.10.24 at 14:32', reason: '3 years ago');
      expect(
        seenTime(tr, at, now),
        '16.10.24 14:32',
        reason: 'Turkish 3 years ago',
      );
    });
  });

  // Server times arrive in UTC. 14:59Z and 15:01Z are the same UTC day but,
  // under TZ=JST-9 (as CI runs), 23:59 on the 18th and 00:01 on the 19th:
  // different local days. Labels must follow the local day.
  group('UTC instants follow the local day', () {
    final nowUtc = DateTime.utc(2026, 10, 18, 15, 1);
    final atUtc = DateTime.utc(2026, 10, 18, 14, 59);
    final atL = atUtc.toLocal();
    final sameLocalDay = atL.day == nowUtc.toLocal().day;
    final hm = '${two(atL.hour)}:${two(atL.minute)}';

    test('dayChipLabel', () {
      expect(
        dayChipLabel(en, atUtc, nowUtc),
        sameLocalDay ? 'Today' : 'October ${atL.day}',
        reason: 'the chip follows the local day, not the UTC day',
      );
      expect(
        dayChipLabel(en, atUtc, nowUtc.toLocal()),
        sameLocalDay ? 'Today' : 'October ${atL.day}',
        reason: 'a UTC message time against a local clock',
      );
    });

    test('seenTime', () {
      expect(
        seenTime(en, atUtc, nowUtc),
        sameLocalDay ? hm : 'yesterday at $hm',
        reason: 'local clock time and local day',
      );
      expect(
        seenTime(tr, atUtc, nowUtc.toLocal()),
        sameLocalDay ? hm : 'dün $hm',
        reason: 'a UTC read time against a local clock',
      );
    });
  });
}

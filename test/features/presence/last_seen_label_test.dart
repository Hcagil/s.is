// lastSeenLabel, written from the contract. Run under TZ=JST-9 like every
// unit test (CI does): the container defaults to UTC, where local and UTC are
// the same clock and the local-time group below cannot tell them apart.
//
// Every other expectation is built from local wall-clock values, so it holds
// in any zone; JST has no daylight saving, so no hour is skipped or repeated.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/presence/domain/last_seen.dart';

void main() {
  final now = DateTime(2026, 9, 23, 15, 40);

  group('the first hour', () {
    test('the same instant is just now', () {
      expect(lastSeenLabel(now, now), 'last seen just now');
    });

    test('59 seconds ago is still just now', () {
      expect(
        lastSeenLabel(now.subtract(const Duration(seconds: 59)), now),
        'last seen just now',
      );
    });

    test('a time in the future (a skewed clock) is just now', () {
      expect(
        lastSeenLabel(now.add(const Duration(minutes: 3)), now),
        'last seen just now',
      );
      expect(
        lastSeenLabel(now.add(const Duration(days: 2)), now),
        'last seen just now',
      );
    });

    test('one minute ago counts in minutes', () {
      expect(
        lastSeenLabel(now.subtract(const Duration(minutes: 1)), now),
        'last seen 1 min ago',
      );
    });

    test('minutes are whole minutes, rounded down', () {
      expect(
        lastSeenLabel(
          now.subtract(const Duration(minutes: 7, seconds: 59)),
          now,
        ),
        'last seen 7 min ago',
      );
    });

    test('59 min 59 s is still minutes', () {
      expect(
        lastSeenLabel(
          now.subtract(const Duration(minutes: 59, seconds: 59)),
          now,
        ),
        'last seen 59 min ago',
      );
    });

    test('an hour ago the same day shows the time of day', () {
      expect(
        lastSeenLabel(now.subtract(const Duration(minutes: 60)), now),
        'last seen today at 14:40',
      );
    });

    test('minutes win across midnight: 40 min ago is not "yesterday"', () {
      expect(
        lastSeenLabel(
          DateTime(2026, 9, 22, 23, 50),
          DateTime(2026, 9, 23, 0, 30),
        ),
        'last seen 40 min ago',
      );
    });
  });

  group('today and yesterday', () {
    test('earlier today, zero-padded', () {
      expect(
        lastSeenLabel(DateTime(2026, 9, 23, 9, 5), now),
        'last seen today at 09:05',
      );
    });

    test('the first second of today is today', () {
      expect(
        lastSeenLabel(DateTime(2026, 9, 23), DateTime(2026, 9, 23, 23, 59)),
        'last seen today at 00:00',
      );
    });

    test('the last second of yesterday is yesterday', () {
      expect(
        lastSeenLabel(
          DateTime(2026, 9, 22, 23, 59, 59),
          DateTime(2026, 9, 23, 1),
        ),
        'last seen yesterday at 23:59',
      );
    });

    test('the first minute of yesterday is yesterday', () {
      expect(
        lastSeenLabel(DateTime(2026, 9, 22, 0, 1), now),
        'last seen yesterday at 00:01',
      );
    });

    test('the last minute of the day before yesterday is a date', () {
      expect(
        lastSeenLabel(
          DateTime(2026, 9, 21, 23, 59),
          DateTime(2026, 9, 23, 0, 5),
        ),
        'last seen 21.09.26',
      );
    });

    test('yesterday across a month boundary', () {
      expect(
        lastSeenLabel(DateTime(2026, 9, 30, 21, 15), DateTime(2026, 10, 1, 8)),
        'last seen yesterday at 21:15',
      );
    });

    test('yesterday across the end of February', () {
      expect(
        lastSeenLabel(DateTime(2027, 2, 28, 21, 15), DateTime(2027, 3, 1, 8)),
        'last seen yesterday at 21:15',
      );
      expect(
        lastSeenLabel(DateTime(2028, 2, 29, 7, 0), DateTime(2028, 3, 1, 8)),
        'last seen yesterday at 07:00',
        reason: 'a leap day is the day before 1 March',
      );
    });

    test('yesterday across a year boundary', () {
      expect(
        lastSeenLabel(
          DateTime(2026, 12, 31, 22, 0),
          DateTime(2027, 1, 1, 0, 30),
        ),
        'last seen yesterday at 22:00',
      );
    });
  });

  group('older', () {
    test('two days ago is a date, dd.MM.yy', () {
      expect(
        lastSeenLabel(DateTime(2026, 9, 21, 12), now),
        'last seen 21.09.26',
      );
    });

    test('single-digit day and month are zero-padded', () {
      expect(
        lastSeenLabel(DateTime(2026, 3, 4, 12), now),
        'last seen 04.03.26',
      );
    });

    test('the same time of day a month ago is not today', () {
      expect(
        lastSeenLabel(DateTime(2026, 8, 23, 15), now),
        'last seen 23.08.26',
      );
    });

    test('the same day a year ago is not today', () {
      expect(
        lastSeenLabel(DateTime(2025, 9, 23, 15), now),
        'last seen 23.09.25',
      );
    });

    test('the same "yesterday" date a month ago is not yesterday', () {
      expect(
        lastSeenLabel(DateTime(2026, 8, 22, 15), now),
        'last seen 22.08.26',
      );
    });

    test('two days back across a year boundary is a date', () {
      expect(
        lastSeenLabel(
          DateTime(2026, 12, 30, 23, 59),
          DateTime(2027, 1, 1, 0, 30),
        ),
        'last seen 30.12.26',
      );
    });
  });

  group('local time', () {
    // The server hands back a UTC instant. Under TZ=JST-9 (UTC+9):
    //   14:00Z on 23 Sep is 23:00 on the 23rd locally, and
    //   16:30Z on 23 Sep is 01:30 on the 24th locally.
    // So locally the member was seen YESTERDAY at 23:00; read in UTC it would
    // be "today at 14:00". Built from local values converted to UTC, so the
    // expectation also holds (without biting) under UTC.
    final atUtc = DateTime(2026, 9, 23, 23).toUtc();
    final nowLocal = DateTime(2026, 9, 24, 1, 30);

    test('a UTC instant is labelled in local time', () {
      expect(lastSeenLabel(atUtc, nowLocal), 'last seen yesterday at 23:00');
    });

    test('a UTC now is compared in local days too', () {
      expect(
        lastSeenLabel(atUtc, nowLocal.toUtc()),
        'last seen yesterday at 23:00',
      );
    });

    test('a UTC instant earlier the same local day shows the local hour', () {
      expect(
        lastSeenLabel(DateTime(2026, 9, 24, 0, 5).toUtc(), nowLocal),
        'last seen today at 00:05',
      );
    });

    test('an older UTC instant shows the local date', () {
      // 00:30 on 2 Sep locally is 15:30Z on 1 Sep: a UTC date says 01.09.
      expect(
        lastSeenLabel(DateTime(2026, 9, 2, 0, 30).toUtc(), nowLocal),
        'last seen 02.09.26',
      );
    });
  });
}

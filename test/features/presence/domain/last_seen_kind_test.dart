// lastSeen: which wording applies, from the contract. Run under TZ=JST-9.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/presence/domain/last_seen.dart';

void main() {
  group('lastSeen', () {
    test('justNow for 0 seconds', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now;
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.justNow);
    });

    test('justNow for 59 seconds', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now.subtract(const Duration(seconds: 59));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.justNow);
    });

    test('justNow for 3 minutes in future', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now.add(const Duration(minutes: 3));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.justNow);
    });

    test('justNow for 2 days in future', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now.add(const Duration(days: 2));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.justNow);
    });

    test('minutesAgo for exactly 60 seconds', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now.subtract(const Duration(seconds: 60));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.minutesAgo);
      expect(result.minutes, 1);
    });

    test('minutesAgo for 59 minutes 59 seconds', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now.subtract(const Duration(minutes: 59, seconds: 59));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.minutesAgo);
      expect(result.minutes, 59);
    });

    test('today for exactly 60 minutes', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = now.subtract(const Duration(minutes: 60));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.today);
    });

    test('today for first instant of today', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = DateTime(now.year, now.month, now.day, 0, 0, 0);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.today);
    });

    test('yesterday for last second of yesterday', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = DateTime(
        now.year,
        now.month,
        now.day,
        0,
        0,
        0,
      ).subtract(const Duration(seconds: 1));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.yesterday);
    });

    test('yesterday for first minute of yesterday', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = DateTime(
        now.year,
        now.month,
        now.day,
        0,
        1,
        0,
      ).subtract(const Duration(days: 1));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.yesterday);
    });

    test('date for last minute of the day before yesterday', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = DateTime(
        now.year,
        now.month,
        now.day,
        23,
        59,
        0,
      ).subtract(const Duration(days: 2));
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.date);
    });

    test('minutesAgo across midnight', () {
      final now = DateTime(2023, 10, 15, 0, 30, 0);
      final at = DateTime(2023, 10, 14, 23, 50, 0);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.minutesAgo);
      expect(result.minutes, 40);
    });

    test('yesterday at month boundary', () {
      final now = DateTime(2023, 10, 1, 8, 0, 0);
      final at = DateTime(2023, 9, 30, 23, 59, 59);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.yesterday);
    });

    test('yesterday at Feb 28 to Mar 1 2027', () {
      final now = DateTime(2027, 3, 1, 8, 0, 0);
      final at = DateTime(2027, 2, 28, 23, 59, 59);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.yesterday);
    });

    test('yesterday at leap day Feb 29 2028 to Mar 1', () {
      final now = DateTime(2028, 3, 1, 8, 0, 0);
      final at = DateTime(2028, 2, 29, 23, 59, 59);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.yesterday);
    });

    test('yesterday at year boundary', () {
      final now = DateTime(2027, 1, 1, 8, 0, 0);
      final at = DateTime(2026, 12, 31, 23, 59, 59);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.yesterday);
    });

    test('date for same day a month ago', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = DateTime(2023, 9, 15, 12, 0, 0);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.date);
    });

    test('date for same day a year ago', () {
      final now = DateTime(2023, 10, 15, 12, 0, 0);
      final at = DateTime(2022, 10, 15, 12, 0, 0);
      final result = lastSeen(at, now);
      expect(result.kind, LastSeenKind.date);
    });
  });

  group('local days', () {
    // Under TZ=JST-9: 14:00Z on 23 Sep is 23:00 on the 23rd locally, and
    // 16:30Z is 01:30 on the 24th. Locally that is yesterday; in UTC, today.
    final atUtc = DateTime(2026, 9, 23, 23).toUtc();
    final nowLocal = DateTime(2026, 9, 24, 1, 30);

    test('a UTC instant is placed on its local day', () {
      expect(lastSeen(atUtc, nowLocal).kind, LastSeenKind.yesterday);
      expect(lastSeen(atUtc, nowLocal.toUtc()).kind, LastSeenKind.yesterday);
    });

    test('a UTC instant earlier the same local day is today', () {
      final at = DateTime(2026, 9, 24, 0, 5).toUtc();
      expect(lastSeen(at, nowLocal).kind, LastSeenKind.today);
    });

    test('at is the instant given', () {
      final r = lastSeen(atUtc, nowLocal);
      expect(r.at.isAtSameMomentAs(atUtc), isTrue);
    });
  });
}

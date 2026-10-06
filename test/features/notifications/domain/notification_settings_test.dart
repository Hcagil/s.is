// Pure domain rules, written from the contract: NotificationSettings
// defaults, MuteLength.until, Mute.activeAt and muteEnd's day boundaries
// (which wording; the words themselves are muteEndLabel's, in presentation).
//
// muteEnd converts to local time before comparing days. Run under
// TZ=JST-9, as CI does: on a machine already in UTC, converting UTC to local
// changes nothing, so a test of that conversion would pass even with
// `.toLocal()` deleted.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';

/// The UTC instant whose JST (UTC+9) clock reads (y, m, d, h:min).
DateTime jst(int y, int m, int d, int h, [int min = 0]) =>
    DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 9));

void main() {
  group('NotificationSettings', () {
    test('defaults are enabled and full preview', () {
      const s = NotificationSettings();
      expect(s.enabled, isTrue);
      expect(s.preview, NotificationPreview.full);
    });

    test('copyWith changes only what is given', () {
      const s = NotificationSettings();
      final off = s.copyWith(enabled: false);
      expect(off.enabled, isFalse);
      expect(off.preview, NotificationPreview.full);

      final sender = s.copyWith(preview: NotificationPreview.sender);
      expect(sender.enabled, isTrue);
      expect(sender.preview, NotificationPreview.sender);
    });

    test('equality is by value', () {
      expect(
        const NotificationSettings(enabled: false),
        const NotificationSettings(enabled: false),
      );
      expect(
        const NotificationSettings(preview: NotificationPreview.none),
        isNot(const NotificationSettings()),
      );
    });
  });

  group('MuteLength', () {
    test('until: 1 h, 8 h, 1 d, 3 d, 7 d — never null', () {
      final now = DateTime.utc(2026, 9, 24, 10);
      const want = {
        MuteLength.oneHour: Duration(hours: 1),
        MuteLength.eightHours: Duration(hours: 8),
        MuteLength.oneDay: Duration(days: 1),
        MuteLength.threeDays: Duration(days: 3),
        MuteLength.oneWeek: Duration(days: 7),
      };
      expect(MuteLength.values.toSet(), want.keys.toSet());
      for (final e in want.entries) {
        expect(e.key.until(now), now.add(e.value), reason: e.key.name);
      }
    });

    test('no picker length is Always; a forever-mute still reads Always', () {
      expect(MuteLength.values.map((l) => l.name), isNot(contains('always')));
      expect(muteEnd(null, DateTime.utc(2026, 9, 24)).day, MuteDay.always);
    });
  });

  group('Mute.activeAt', () {
    test('null until is always active', () {
      const m = Mute(kind: MuteKind.person, target: 'u1');
      expect(m.activeAt(DateTime.utc(2100)), isTrue);
    });

    test('a future until is active', () {
      final now = DateTime.utc(2026, 9, 24, 10);
      final m = Mute(
        kind: MuteKind.person,
        target: 'u1',
        until: now.add(const Duration(minutes: 1)),
      );
      expect(m.activeAt(now), isTrue);
    });

    test('a past until is not active', () {
      final now = DateTime.utc(2026, 9, 24, 10);
      final m = Mute(
        kind: MuteKind.person,
        target: 'u1',
        until: now.subtract(const Duration(minutes: 1)),
      );
      expect(m.activeAt(now), isFalse);
    });

    test('until exactly now is no longer active', () {
      final now = DateTime.utc(2026, 9, 24, 10);
      final m = Mute(kind: MuteKind.person, target: 'u1', until: now);
      expect(m.activeAt(now), isFalse);
    });
  });

  group('muteEnd', () {
    void expectEnd(DateTime? until, DateTime now, MuteDay day) {
      final r = muteEnd(until, now);
      expect(r.day, day);
      if (until == null) {
        expect(r.at, isNull);
      } else {
        expect(r.at!.isAtSameMomentAs(until), isTrue, reason: '${r.at}');
      }
    }

    test('null is always, with no time', () {
      expectEnd(null, DateTime.utc(2026, 9, 24), MuteDay.always);
    });

    test('the same local day is today', () {
      expectEnd(jst(2026, 9, 24, 18, 5), jst(2026, 9, 24, 8), MuteDay.today);
    });

    test('the last minute of the local day is still today', () {
      expectEnd(jst(2026, 9, 24, 23, 59), jst(2026, 9, 24, 0), MuteDay.today);
    });

    test('local midnight is tomorrow', () {
      expectEnd(jst(2026, 9, 25, 0), jst(2026, 9, 24, 23), MuteDay.tomorrow);
    });

    test('the last minute of the next local day is tomorrow', () {
      expectEnd(
        jst(2026, 9, 25, 23, 59),
        jst(2026, 9, 24, 0),
        MuteDay.tomorrow,
      );
    });

    test('two local days on is later', () {
      expectEnd(jst(2026, 9, 26, 0), jst(2026, 9, 24, 23, 59), MuteDay.later);
      expectEnd(jst(2026, 10, 3, 18, 5), jst(2026, 9, 24, 9), MuteDay.later);
    });

    test('tomorrow across a month and a year boundary', () {
      expectEnd(jst(2026, 10, 1, 9), jst(2026, 9, 30, 22), MuteDay.tomorrow);
      expectEnd(jst(2027, 1, 1, 9), jst(2026, 12, 31, 22), MuteDay.tomorrow);
    });

    test('the same time a month on is later, not today', () {
      expectEnd(jst(2026, 10, 24, 9), jst(2026, 9, 24, 9), MuteDay.later);
    });

    test('a UTC day boundary that is not a local one is today', () {
      // 23:00Z on the 24th is 08:00 JST on the 25th; 01:00Z on the 25th is
      // 10:00 JST, the same local day.
      final now = DateTime.utc(2026, 9, 24, 23);
      final until = DateTime.utc(2026, 9, 25, 1);
      expect(now.day, isNot(until.day), reason: 'setup: different UTC day');
      expect(now.toLocal().day, until.toLocal().day, reason: 'setup');
      expectEnd(until, now, MuteDay.today);
    });

    test('a local day boundary inside one UTC day is tomorrow', () {
      // 14:00Z and 16:00Z on the 30th are 23:00 JST on the 30th and 01:00
      // JST on the 1st.
      final now = DateTime.utc(2026, 9, 30, 14);
      final until = DateTime.utc(2026, 9, 30, 16);
      expect(now.day, until.day, reason: 'setup: same UTC day');
      expect(now.toLocal().day, isNot(until.toLocal().day), reason: 'setup');
      expectEnd(until, now, MuteDay.tomorrow);
    });
  });
}

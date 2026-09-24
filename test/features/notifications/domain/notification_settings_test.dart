// Pure domain rules, written from the contract: NotificationSettings
// defaults, MuteLength.until, Mute.activeAt and muteLabel's day-boundary
// wording.
//
// muteLabel converts to local time before comparing days. Run under
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
    test('until: 8 hours, 1 week, or null for always', () {
      final now = DateTime.utc(2026, 9, 24, 10);
      expect(
        MuteLength.eightHours.until(now),
        now.add(const Duration(hours: 8)),
      );
      expect(MuteLength.oneWeek.until(now), now.add(const Duration(days: 7)));
      expect(MuteLength.always.until(now), isNull);
    });

    test('labels', () {
      expect(MuteLength.eightHours.label, '8 hours');
      expect(MuteLength.oneWeek.label, '1 week');
      expect(MuteLength.always.label, 'Always');
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

  group('muteLabel', () {
    test('null is "Always"', () {
      expect(muteLabel(null, DateTime.utc(2026, 9, 24)), 'Always');
    });

    test('same local day: "Until HH:mm"', () {
      final now = jst(2026, 9, 24, 8, 0);
      final until = jst(2026, 9, 24, 18, 5);
      expect(muteLabel(until, now), 'Until 18:05');
    });

    test('single-digit hour and minute are zero-padded', () {
      final now = jst(2026, 9, 24, 0, 0);
      final until = jst(2026, 9, 24, 5, 3);
      expect(muteLabel(until, now), 'Until 05:03');
    });

    test('the next local day: "Until tomorrow HH:mm"', () {
      final now = jst(2026, 9, 24, 23, 0);
      final until = jst(2026, 9, 25, 9, 0);
      expect(muteLabel(until, now), 'Until tomorrow 09:00');
    });

    test('later than tomorrow: "Until D Mon HH:mm"', () {
      final now = jst(2026, 9, 24, 9, 0);
      final until = jst(2026, 10, 3, 18, 5);
      expect(muteLabel(until, now), 'Until 3 Oct 18:05');
    });

    test('a UTC day boundary that is not a local one still reads as today: '
        'proves the comparison is done in local time, not UTC', () {
      // 23:00 UTC on the 24th is 08:00 JST on the 25th; 01:00 UTC on the
      // 25th is 10:00 JST, the same local day. In UTC these are two
      // different calendar days.
      final now = DateTime.utc(2026, 9, 24, 23, 0);
      final until = DateTime.utc(2026, 9, 25, 1, 0);
      expect(now.day, isNot(until.day), reason: 'setup: different UTC day');
      expect(
        now.toLocal().day,
        until.toLocal().day,
        reason: 'setup: same local day',
      );
      expect(muteLabel(until, now), 'Until 10:00');
    });

    test('a local day that only differs by the timezone reads as tomorrow, '
        'not the same day, once converted', () {
      // Both instants fall on UTC the 30th, but 16:00 UTC is already
      // 01:00 JST on the 1st — the next local day from 14:00 UTC's 23:00.
      final now = DateTime.utc(2026, 9, 30, 14, 0);
      final until = DateTime.utc(2026, 9, 30, 16, 0);
      expect(now.day, until.day, reason: 'setup: same UTC day');
      expect(
        now.toLocal().day,
        isNot(until.toLocal().day),
        reason: 'setup: different local day',
      );
      expect(muteLabel(until, now), 'Until tomorrow 01:00');
    });
  });
}

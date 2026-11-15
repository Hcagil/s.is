import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_dashboard.dart';

void main() {
  group('AdminRateLimit.tryParse', () {
    test('returns null for invalid raw values', () {
      expect(AdminRateLimit.tryParse(null), isNull);
      expect(AdminRateLimit.tryParse('text'), isNull);
      expect(AdminRateLimit.tryParse(42), isNull);
      expect(AdminRateLimit.tryParse([]), isNull);
      expect(AdminRateLimit.tryParse({}), isNull);
    });

    test('returns null for missing or invalid fields', () {
      expect(AdminRateLimit.tryParse({'kind': 'five_hour'}), isNull);
      expect(
        AdminRateLimit.tryParse({'kind': 'five_hour', 'percentUsed': 'abc'}),
        isNull,
      );
      expect(
        AdminRateLimit.tryParse({
          'kind': 'five_hour',
          'percentUsed': double.nan,
        }),
        isNull,
      );
      expect(AdminRateLimit.tryParse({'kind': '', 'percentUsed': 5}), isNull);
      expect(AdminRateLimit.tryParse({'percentUsed': 5}), isNull);
      expect(AdminRateLimit.tryParse({'kind': 7, 'percentUsed': 5}), isNull);
    });

    test('parses valid entries correctly', () {
      final raw = {
        'kind': 'five_hour',
        'percentUsed': 42,
        'resetsAt': '2026-11-15T14:30:00Z',
      };
      final rate = AdminRateLimit.tryParse(raw);
      expect(rate, isNotNull);
      expect(rate!.kind, equals('five_hour'));
      expect(rate.percentUsed, equals(42));
      expect(rate.resetsAt, equals('2026-11-15T14:30:00Z'));

      final rawWithDouble = {
        'kind': 'five_hour',
        'percentUsed': 42.0,
        'resetsAt': '2026-11-15T14:30:00Z',
      };
      final rateDouble = AdminRateLimit.tryParse(rawWithDouble);
      expect(rateDouble, isNotNull);
      expect(rateDouble!.percentUsed, equals(42));

      final rawWithoutResets = {'kind': 'five_hour', 'percentUsed': 42};
      final rateNoReset = AdminRateLimit.tryParse(rawWithoutResets);
      expect(rateNoReset, isNotNull);
      expect(rateNoReset!.resetsAt, isNull);

      final rawBadResets = {
        'kind': 'five_hour',
        'percentUsed': 42,
        'resetsAt': 123,
      };
      final rateBadReset = AdminRateLimit.tryParse(rawBadResets);
      expect(rateBadReset, isNotNull);
      expect(rateBadReset!.resetsAt, isNull);
    });
  });

  group('AdminDashboard.usage', () {
    test('default constructor has empty usage', () {
      final dashboard = AdminDashboard(working: const [], sessions: const []);
      expect(dashboard.usage, isEmpty);
    });

    test('fromFields with empty or malformed data yields empty usage', () {
      expect(AdminDashboard.fromFields({}).usage, isEmpty);
      expect(AdminDashboard.fromFields({'usage': 'x'}).usage, isEmpty);
      expect(
        AdminDashboard.fromFields({
          'usage': {'rateLimits': 'x'},
        }).usage,
        isEmpty,
      );
    });

    test('parses only valid rate limits', () {
      final dashboard = AdminDashboard.fromFields({
        'usage': {
          'rateLimits': [
            'bad',
            null,
            {'kind': 'five_hour'},
            {'kind': 'seven_day', 'percentUsed': 10},
            {'kind': 'spend_limit', 'percentUsed': 95},
          ],
        },
      });

      final kinds = dashboard.usage.map((r) => r.kind).toList();
      final percentUsed = dashboard.usage.map((r) => r.percentUsed).toList();

      expect(kinds, equals(['seven_day', 'spend_limit']));
      expect(percentUsed, equals([10, 95]));
    });
  });
}

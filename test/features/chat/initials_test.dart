import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/initials.dart';

void main() {
  const cases = {
    'Ela Demir': 'ED',
    'Family': 'F',
    '  weekend   plan  now': 'WP',
    'ela demir': 'ED',
    'Ela\tDemir': 'ED',
    'Ela Demir Kaya Öz': 'ED',
    'ömer çelik': 'ÖÇ',
    '': '?',
    '   ': '?',
  };
  for (final MapEntry(key: name, value: want) in cases.entries) {
    test('initialsOf(${name.isEmpty ? '<empty>' : '"$name"'}) is $want', () {
      expect(initialsOf(name), want);
    });
  }
}

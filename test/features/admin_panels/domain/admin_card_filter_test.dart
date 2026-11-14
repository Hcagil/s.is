import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_card_filter.dart';
import 'package:sis/features/admin_panels/domain/admin_models.dart';

AdminCard card(
  String id, {
  String type = 'rule',
  String state = 'active',
  String? applies,
  String? area,
  String oneLiner = '',
  List<String> words = const [],
  String? allows,
  String? forbids,
}) => AdminCard(
  id: id,
  type: type,
  state: state,
  applies: applies,
  area: area,
  when: const [],
  oneLiner: oneLiner,
  words: words,
  allows: allows,
  forbids: forbids,
);

void main() {
  group('adminFilterCards', () {
    test('no filters returns all cards in order', () {
      final cards = [
        card('X1', oneLiner: 'First card', words: ['alpha']),
        card('X2', allows: 'allowAlpha'),
        card('X3', forbids: 'forbidAlpha'),
        card('X4', type: 'app', area: 'release'),
        card('X5', type: 'rule', applies: 'M, L'),
        card('X6', type: 'rule', applies: 'L,  X'),
        card('X7', type: 'rule', applies: null),
        card('X8', type: 'rule', applies: ''),
        card('X9', type: 'rule', applies: ' , '),
        card('X10', type: 'app', area: 'build'),
        card('X11', type: 'app', area: null),
        card('X12', state: 'proposed', oneLiner: 'Alpha proposed'),
        card(
          'X13',
          state: 'proposed',
          type: 'rule',
          applies: 'M, L',
          oneLiner: 'Alpha proposed',
        ),
      ];
      expect(adminFilterCards(cards), equals(cards));
    });

    test('query matches only in id (case-insensitive)', () {
      final cards = [
        card('AB1', oneLiner: 'First card', words: ['alpha']),
        card('CD2', allows: 'allowAlpha'),
      ];
      final result = adminFilterCards(cards, query: 'ab1');
      expect(result, equals([cards[0]]));
    });

    test('query matches only in oneLiner', () {
      final cards = [
        card('AB1', oneLiner: 'First card', words: ['alpha']),
        card('CD2', allows: 'allowAlpha'),
      ];
      final result = adminFilterCards(cards, query: 'first');
      expect(result, equals([cards[0]]));
    });

    test('query matches only in words', () {
      final cards = [
        card('AB1', oneLiner: 'First card', words: ['alpha']),
        card('CD2', words: ['alpha']),
        card('EF3', words: ['beta']),
      ];
      final result = adminFilterCards(cards, query: 'alpha');
      expect(result, equals([cards[0], cards[1]]));
    });

    test('query matches only in allows', () {
      final cards = [
        card('AB1', allows: 'allowAlpha'),
        card('CD2', allows: 'allowBeta'),
      ];
      final result = adminFilterCards(cards, query: 'allowalpha');
      expect(result, equals([cards[0]]));
    });

    test('query matches only in forbids', () {
      final cards = [
        card('AB1', forbids: 'forbidAlpha'),
        card('CD2', forbids: 'forbidBeta'),
      ];
      final result = adminFilterCards(cards, query: 'forbidalpha');
      expect(result, equals([cards[0]]));
    });

    test('query with padded spaces behaves like trimmed', () {
      final cards = [
        card('AB1', oneLiner: 'Alpha card'),
        card('CD2', oneLiner: 'Beta card'),
      ];
      final padded = adminFilterCards(cards, query: '  alpha  ');
      final trimmed = adminFilterCards(cards, query: 'alpha');
      expect(padded, equals(trimmed));
    });

    test('query with only spaces returns all', () {
      final cards = [
        card('AB1', oneLiner: 'Alpha card'),
        card('CD2', oneLiner: 'Beta card'),
      ];
      final result = adminFilterCards(cards, query: '   ');
      expect(result, equals(cards));
    });

    test('query not present anywhere returns empty list', () {
      final cards = [
        card('AB1', oneLiner: 'Alpha card'),
        card('CD2', oneLiner: 'Beta card'),
      ];
      final result = adminFilterCards(cards, query: 'nonexistent');
      expect(result, isEmpty);
    });

    test('state filter', () {
      final cards = [
        card('X1', state: 'proposed'),
        card('X2', state: 'active'),
        card('X3', state: 'proposed'),
      ];
      final result = adminFilterCards(cards, state: 'proposed');
      expect(result, equals([cards[0], cards[2]]));
    });

    test('type filter', () {
      final cards = [
        card('X1', type: 'app'),
        card('X2', type: 'rule'),
        card('X3', type: 'app'),
      ];
      final result = adminFilterCards(cards, type: 'app');
      expect(result, equals([cards[0], cards[2]]));
    });

    test('value filter for rule cards', () {
      final cards = [
        card('X1', type: 'rule', applies: 'M, L'),
        card('X2', type: 'rule', applies: 'L,  X'),
        card('X3', type: 'rule', applies: null),
        card('X4', type: 'rule', applies: ''),
        card('X5', type: 'rule', applies: ' , '),
        card('X6', type: 'app', area: 'release'),
        card('X7', type: 'rule', applies: 'M, L', oneLiner: 'Alpha proposed'),
      ];
      final m = adminFilterCards(cards, type: 'rule', value: 'M');
      expect(m, equals([cards[0], cards[6]]));
      final l = adminFilterCards(cards, type: 'rule', value: 'L');
      expect(l, equals([cards[0], cards[1], cards[6]]));
    });

    test('value filter for app cards', () {
      final cards = [
        card('X1', type: 'app', area: 'release'),
        card('X2', type: 'app', area: 'build'),
        card('X3', type: 'app', area: null),
        card('X4', type: 'rule', applies: 'M, L'),
      ];
      final result = adminFilterCards(cards, type: 'app', value: 'release');
      expect(result, equals([cards[0]]));
    });

    test('AND combination of filters', () {
      final cards = [
        card(
          'X1',
          state: 'proposed',
          type: 'rule',
          oneLiner: 'alpha',
          applies: 'M, L',
        ),
        card(
          'X2',
          state: 'proposed',
          type: 'rule',
          oneLiner: 'beta',
          applies: 'M, L',
        ),
        card(
          'X3',
          state: 'proposed',
          type: 'app',
          oneLiner: 'alpha',
          area: 'M',
        ),
        card(
          'X4',
          state: 'active',
          type: 'rule',
          oneLiner: 'alpha',
          applies: 'M, L',
        ),
        card(
          'X5',
          state: 'proposed',
          type: 'rule',
          oneLiner: 'alpha',
          applies: 'L',
        ),
      ];
      final result = adminFilterCards(
        cards,
        state: 'proposed',
        type: 'rule',
        query: 'alpha',
        value: 'M',
      );
      expect(result, equals([cards[0]]));
    });
  });

  group('adminCardValues', () {
    final cards = [
      card('C-5', type: 'rule', applies: 'M, L'),
      card('C-6', type: 'rule', applies: 'L,  X'),
      card('C-7', type: 'rule', applies: null),
      card('C-8', type: 'rule', applies: ''),
      card('C-9', type: 'rule', applies: ' , '),
      card('C-4', type: 'app', area: 'release'),
      card('C-10', type: 'app', area: 'build'),
      card('C-11', type: 'app', area: null),
    ];

    test('adminCardValues for rule', () {
      final result = adminCardValues(cards, 'rule');
      expect(result, equals(['L', 'M', 'X']));
    });

    test('adminCardValues for app', () {
      final result = adminCardValues(cards, 'app');
      expect(result, equals(['build', 'release']));
    });

    test('adminCardValues with empty list', () {
      final result = adminCardValues([], 'rule');
      expect(result, isEmpty);
    });
  });
}

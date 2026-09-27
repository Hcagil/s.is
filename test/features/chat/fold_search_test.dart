import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  group('foldSearch', () {
    test('folds Turkish characters to lowercase i', () {
      expect(foldSearch('İstanbul'), equals('istanbul'));
    });

    test('folds uppercase I to lowercase i', () {
      expect(foldSearch('ISTANBUL'), equals('istanbul'));
    });

    test('folds lowercase ı to lowercase i', () {
      expect(foldSearch('ıstanbul'), equals('istanbul'));
    });

    test('folds mixed case', () {
      expect(foldSearch('Istanbul'), equals('istanbul'));
    });

    test('does not alter other characters', () {
      expect(foldSearch('ŞÇĞÜÖ'), equals('şçğüö'));
    });

    test('keeps accents', () {
      expect(foldSearch('Café'), equals('café'));
    });

    test('preserves whitespace', () {
      expect(foldSearch('  A  '), equals('  a  '));
    });

    test('keeps digits unchanged', () {
      expect(foldSearch('123'), equals('123'));
    });

    test('empty string remains empty', () {
      expect(foldSearch(''), equals(''));
    });

    test('combining sequence İ remains i̇', () {
      expect(foldSearch('I\u0307'), equals('i\u0307'));
    });

    test('İ becomes single i', () {
      expect(foldSearch('\u0130'), equals('i'));
    });

    test('every i form in one string folds to plain i, nothing else moves', () {
      expect(
        foldSearch('\u0130I\u0131i I\u011eDIR \u0131\u011fd\u0131r'),
        'iiii i\u011fdir i\u011fdir',
      );
    });

    test(
      '\u0130 inside a word folds to one character, the word keeps its length',
      () {
        final folded = foldSearch('K\u0130L\u0130T');
        expect(folded, 'kilit');
        expect(folded.length, 5);
      },
    );
  });

  group('isSearchable', () {
    test('returns true for 3 letters', () {
      expect(isSearchable('abc'), isTrue);
    });

    test('returns false for 2 letters', () {
      expect(isSearchable('ab'), isFalse);
    });

    test('returns false for trimmed 2 letters', () {
      expect(isSearchable(' ab '), isFalse);
    });

    test('returns true for 3 letters separated by spaces', () {
      expect(isSearchable('a b c'), isTrue);
    });

    test('returns false for punctuation only', () {
      expect(isSearchable('...'), isFalse);
    });

    test('returns false for symbols only', () {
      expect(isSearchable('!!!'), isFalse);
    });

    test('returns false for emoji only', () {
      expect(isSearchable('😂😂😂'), isFalse);
    });

    test('returns false for letters with punctuation', () {
      expect(isSearchable('h..'), isFalse);
    });

    test('returns true for 3 digits', () {
      expect(isSearchable('123'), isTrue);
    });

    test('returns true for non-Latin letters', () {
      expect(isSearchable('çğü'), isTrue);
    });

    test('returns true for Japanese', () {
      expect(isSearchable('日本語'), isTrue);
    });

    test('returns true for letters and digits', () {
      expect(isSearchable('ab1'), isTrue);
    });

    test('returns false for empty string', () {
      expect(isSearchable(''), isFalse);
    });

    test('returns false for 2 letters separated by punctuation', () {
      expect(isSearchable('a,b'), isFalse);
    });

    test('returns true for 3 letters separated by punctuation', () {
      expect(isSearchable('a,b,c'), isTrue);
    });

    test('returns false for 2 digits separated by punctuation', () {
      expect(isSearchable('1,2'), isFalse);
    });

    test('returns true for 3 digits separated by punctuation', () {
      expect(isSearchable('1,2,3'), isTrue);
    });

    test('returns true for mixed letters and digits', () {
      expect(isSearchable('a1b'), isTrue);
    });

    test('returns false for mixed but less than 3', () {
      expect(isSearchable('a1'), isFalse);
    });

    test('returns true for letters with spaces and punctuation', () {
      expect(isSearchable('a, b. c'), isTrue);
    });

    test(
      'returns false for letters with spaces and punctuation but less than 3',
      () {
        expect(isSearchable('a, b'), isFalse);
      },
    );

    test('returns false for whitespace only', () {
      expect(isSearchable('   '), isFalse);
    });

    test('returns false for punctuation and digits but less than 3', () {
      expect(isSearchable('1..'), isFalse);
    });

    test('returns true for digits and letters separated by spaces', () {
      expect(isSearchable('1 a 2'), isTrue);
    });

    test('returns false for digits and letters separated by spaces but less than 3', () {
      expect(isSearchable('1 a'), isFalse);
    });
  });
}

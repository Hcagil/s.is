import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/highlight.dart';

void main() {
  group('matchOffsets', () {
    test('single match at the start, middle, and end', () {
      final text = 'start middle end';
      expect(matchOffsets(text, 'start'), equals([0]));
      expect(matchOffsets(text, 'middle'), equals([6]));
      expect(matchOffsets(text, 'end'), equals([13]));
    });

    test('multiple non-overlapping matches in ascending order', () {
      final text = 'test test test';
      expect(matchOffsets(text, 'test'), equals([0, 5, 10]));
    });

    test('case-insensitive matching', () {
      expect(matchOffsets('apple', 'APPLE'), equals([0]));
      expect(matchOffsets('APPLE', 'apple'), equals([0]));
      expect(matchOffsets('Apple APPLE apple', 'aPPle'), equals([0, 6, 12]));
    });

    test('non-overlapping behavior', () {
      expect(matchOffsets('aaaa', 'aa'), equals([0, 2]));
      expect(matchOffsets('aaa', 'aa'), equals([0]));
      expect(matchOffsets('banana', 'ana'), equals([1]));
    });

    test('no matches', () {
      expect(matchOffsets('abc', 'xyz'), equals([]));
    });

    test('blank query returns empty list', () {
      expect(matchOffsets('any text', ''), equals([]));
      expect(matchOffsets('any text', '   '), equals([]));
    });

    test('query longer than text returns empty', () {
      expect(matchOffsets('short', 'longer'), equals([]));
    });

    test('query equal to the whole text', () {
      expect(matchOffsets('hello', 'hello'), equals([0]));
    });

    test('empty text returns empty list', () {
      expect(matchOffsets('', 'anything'), equals([]));
    });

    test('special regex characters are treated literally', () {
      expect(matchOffsets('a.b.c', '.'), equals([1, 3]));
      expect(matchOffsets('xa+by', 'a+b'), equals([1]));
      expect(matchOffsets('f(x) g(x)', '(x)'), equals([1, 6]));
      expect(matchOffsets('ab', '*'), equals([]));
    });

    test('UTF-16 code unit indices', () {
      // 😀 is a surrogate pair (2 code units)
      // String: 😀 x 😀 x
      // Indices: 0 1 2 3 4 5
      expect(matchOffsets('😀x😀x', 'x'), equals([2, 5]));
    });

    test('query containing a space', () {
      final text = 'I love New York and new york';
      expect(matchOffsets(text, 'new york'), equals([7, 20]));
    });
  });
}

// The pure rules of the profile domain, from the contract: how a typed tag is
// normalised, and that the client's idea of a well-formed tag and name is the
// database's — a client stricter or looser than the check constraint either
// blocks a valid tag or lets a doomed save go to the server.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';

void main() {
  group('normaliseTag', () {
    test('trims, strips a leading @ and lower-cases', () {
      expect(normaliseTag('  @Maya_R  '), 'maya_r');
      expect(normaliseTag('MAYA'), 'maya');
      expect(normaliseTag('@maya'), 'maya');
      expect(normaliseTag('maya'), 'maya');
    });

    test('keeps an @ that is not leading', () {
      expect(normaliseTag('ma@ya'), 'ma@ya');
    });
  });

  group('tagProblem agrees with the database check constraint', () {
    final samples = [
      'abc', 'a12', 'a_b', 'maya_r', 'a${'b' * 19}', // valid
      '', 'a', 'ab', 'a${'b' * 20}', '1abc', '_abc', 'ab-c', 'ab c', 'ab.c',
      'Abc', 'abC', 'çok', 'ağa', '@abc', 'abc!', // invalid
    ];
    for (final tag in samples) {
      final valid = dbTagPattern.hasMatch(tag);
      test('"$tag" is ${valid ? 'accepted' : 'refused'}', () {
        final problem = tagProblem(tag);
        if (valid) {
          expect(problem, isNull, reason: 'a tag the database accepts');
        } else {
          expect(problem, isNotNull, reason: 'a tag the database refuses');
          expect(problem, isNotEmpty);
        }
      });
    }

    test('the boundaries are 3 and 20 characters', () {
      expect(tagProblem('abc'), isNull);
      expect(tagProblem('ab'), isNotNull);
      expect(tagProblem('a' * 20), isNull);
      expect(tagProblem('a' * 21), isNotNull);
    });
  });

  group('displayNameProblem', () {
    test('an empty or blank name is a problem', () {
      expect(displayNameProblem(''), isNotNull);
      expect(displayNameProblem('   '), isNotNull);
    });

    test('1 to 80 characters is fine, 81 is not', () {
      expect(maxDisplayNameLength, 80);
      expect(displayNameProblem('M'), isNull);
      expect(displayNameProblem('Çağıl Öztürk'), isNull);
      expect(displayNameProblem('z' * 80), isNull);
      expect(displayNameProblem('z' * 81), isNotNull);
    });
  });
}

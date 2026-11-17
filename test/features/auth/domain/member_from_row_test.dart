import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';

void main() {
  group('Member.fromRow', () {
    test('returns a Member with all fields when all keys are present', () {
      final row = {
        'user_id': 'u1',
        'display_name': 'Maya',
        'tag': 'admin',
        'avatar_path': '/avatars/u1.png',
      };
      final member = Member.fromRow(row);
      expect(member.userId, 'u1');
      expect(member.displayName, 'Maya');
      expect(member.tag, 'admin');
      expect(member.avatarPath, '/avatars/u1.png');
    });

    test('returns a Member with null tag and avatarPath when only required keys are present', () {
      final row = {'user_id': 'u2', 'display_name': 'John'};
      final member = Member.fromRow(row);
      expect(member.userId, 'u2');
      expect(member.displayName, 'John');
      expect(member.tag, isNull);
      expect(member.avatarPath, isNull);
    });

    test(
      'avatarPath is null when avatar_path key is present with null value',
      () {
        final row = {
          'user_id': 'u3',
          'display_name': 'Alice',
          'tag': 'user',
          'avatar_path': null,
        };
        final member = Member.fromRow(row);
        expect(member.userId, 'u3');
        expect(member.displayName, 'Alice');
        expect(member.tag, 'user');
        expect(member.avatarPath, isNull);
      },
    );

    test('ignores unknown keys without throwing', () {
      final row = {
        'user_id': 'u4',
        'display_name': 'Bob',
        'email': 'bob@mail.test',
      };
      final member = Member.fromRow(row);
      expect(member.userId, 'u4');
      expect(member.displayName, 'Bob');
      expect(member.tag, isNull);
      expect(member.avatarPath, isNull);
    });

    test('throws when user_id key is missing', () {
      final row = {'display_name': 'Charlie'};
      expect(() => Member.fromRow(row), throwsA(anything));
    });

    test('throws when user_id value is not a String', () {
      final row = {'user_id': 5, 'display_name': 'Dana'};
      expect(() => Member.fromRow(row), throwsA(anything));
    });
  });
}

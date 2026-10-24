// securityCode known-answer vectors, computed independently from the
// derivation in the security design check (version || curve || ed || uuid,
// 5200 x SHA-512(h || curve || ed), 6 x 5-byte chunks mod 100000), smaller
// id first. Drafted by test_writer from the contract; reviewed by qa-lead.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/crypto/domain/security_code.dart';

void main() {
  // Fixtures
  const idA = '00000000-0000-4000-8000-00000000000a';
  const idB = '00000000-0000-4000-8000-00000000000b';
  const c11 = 'ERERERERERERERERERERERERERERERERERERERERERE=';
  const e22 = 'IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=';
  const c33 = 'MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=';
  const e44 = 'REREREREREREREREREREREREREREREREREREREREREQ=';
  const cSeq = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
  final a = CodeParty(userId: idA, curve25519: c11, ed25519: e22);
  final b = CodeParty(userId: idB, curve25519: c33, ed25519: e44);

  group('securityCode', () {
    test('known answers', () {
      expect(
        securityCode(a, b),
        equals('641231018949145774472639426382083927211796311914359524400325'),
      );
      expect(
        securityCode(b, a),
        equals('641231018949145774472639426382083927211796311914359524400325'),
      );
    });

    test('b curve25519 replaced by cSeq', () {
      final b2 = CodeParty(userId: idB, curve25519: cSeq, ed25519: e44);
      expect(
        securityCode(a, b2),
        equals('641231018949145774472639426382837343994738377272804875749977'),
      );
    });

    test('ids swapped', () {
      final a2 = CodeParty(userId: idB, curve25519: c11, ed25519: e22);
      final b2 = CodeParty(userId: idA, curve25519: c33, ed25519: e44);
      expect(
        securityCode(a2, b2),
        equals('449591387879758601995422348942206318605373202990013519050984'),
      );
    });

    test('uppercase hex ids', () {
      final a3 = CodeParty(
        userId: 'a0000000-0000-4000-8000-000000000000',
        curve25519: c11,
        ed25519: e22,
      );
      final b3 = CodeParty(
        userId: 'F0000000-0000-4000-8000-000000000000',
        curve25519: c33,
        ed25519: e44,
      );
      expect(
        securityCode(a3, b3),
        equals('544330044956602505178965552689804424805157760092331439591624'),
      );
      expect(
        securityCode(b3, a3),
        equals('544330044956602505178965552689804424805157760092331439591624'),
      );
    });

    test('padding-free base64', () {
      final aPad = CodeParty(
        userId: idA,
        curve25519: c11.substring(0, c11.length - 1),
        ed25519: e22.substring(0, e22.length - 1),
      );
      final bPad = CodeParty(
        userId: idB,
        curve25519: c33.substring(0, c33.length - 1),
        ed25519: e44.substring(0, e44.length - 1),
      );
      expect(securityCode(aPad, bPad), equals(securityCode(a, b)));
    });

    test('changing ed25519 changes code', () {
      final aE44 = CodeParty(userId: idA, curve25519: c11, ed25519: e44);
      expect(securityCode(aE44, b), isNot(equals(securityCode(a, b))));
    });

    test('changing id changes code', () {
      final aIdChanged = CodeParty(
        userId: '00000000-0000-4000-8000-00000000000c',
        curve25519: c11,
        ed25519: e22,
      );
      expect(securityCode(aIdChanged, b), isNot(equals(securityCode(a, b))));
    });

    test('60 digits, nothing else', () {
      expect(securityCode(a, b), matches(RegExp(r'^\d{60}$')));
    });

    test('null when ids equal', () {
      final sameId = CodeParty(userId: idA, curve25519: c11, ed25519: e22);
      expect(securityCode(sameId, sameId), isNull);
    });

    test('null for malformed inputs', () {
      final invalidIds = [
        'not-a-uuid',
        '',
        '00000000-0000-4000-8000-00000000000', // missing one hex
        '00000000-0000-4000-8000-00000000000g', // non-hex
      ];
      for (final id in invalidIds) {
        final party = CodeParty(userId: id, curve25519: c11, ed25519: e22);
        expect(securityCode(party, b), isNull);
        expect(securityCode(b, party), isNull);
      }

      final badCurve = CodeParty(userId: idA, curve25519: '***', ed25519: e22);
      expect(securityCode(badCurve, b), isNull);
      expect(securityCode(b, badCurve), isNull);

      final key31 = CodeParty(
        userId: idA,
        curve25519: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',
        ed25519: e22,
      );
      expect(securityCode(key31, b), isNull);
      expect(securityCode(b, key31), isNull);

      final key33 = CodeParty(
        userId: idA,
        curve25519: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ed25519: e22,
      );
      expect(securityCode(key33, b), isNull);
      expect(securityCode(b, key33), isNull);

      final emptyEd = CodeParty(userId: idA, curve25519: c11, ed25519: '');
      expect(securityCode(emptyEd, b), isNull);
      expect(securityCode(b, emptyEd), isNull);
    });
  });

  group('securityCodeLines', () {
    test('correct formatting', () {
      final digits =
          '641231018949145774472639426382083927211796311914359524400325';
      expect(
        securityCodeLines(digits),
        equals([
          '64123 10189 49145 77447',
          '26394 26382 08392 72117',
          '96311 91435 95244 00325',
        ]),
      );
    });

    test('throws for invalid lengths', () {
      final tooShort = List.filled(59, '1').join('');
      final tooLong = List.filled(61, '1').join('');
      expect(() => securityCodeLines(''), throwsArgumentError);
      expect(() => securityCodeLines(tooShort), throwsArgumentError);
      expect(() => securityCodeLines(tooLong), throwsArgumentError);
    });
  });
}

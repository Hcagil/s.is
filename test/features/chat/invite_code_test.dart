import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/invite_link.dart';

const code = 'Ab3-_Zx9Qw7Lm2Kp4Rt6Yv8N';
const other = '0123456789abcdefABCDEFgh';

void main() {
  group('inviteCodeFrom', () {
    test('bare code returns code', () {
      expect(inviteCodeFrom(code), equals(code));
    });

    test('code with leading/trailing spaces returns code', () {
      expect(inviteCodeFrom('  $code  '), equals(code));
    });

    test('code with trailing newline and leading tab returns code', () {
      expect(inviteCodeFrom('\t$code\n'), equals(code));
    });

    test('URL with path returns code', () {
      expect(
        inviteCodeFrom('https://invite.sis.test/join/$code'),
        equals(code),
      );
    });

    test('URL with hash returns code', () {
      expect(inviteCodeFrom('https://invite.sis.test/j#$code'), equals(code));
    });

    test('URL with query returns code', () {
      expect(inviteCodeFrom('https://invite.sis.test/j?c=$code'), equals(code));
    });

    test('URL with leading spaces and trailing newline returns code', () {
      expect(
        inviteCodeFrom('  https://invite.sis.test/join/$code\n'),
        equals(code),
      );
    });

    test('code with - and _ inside is kept intact', () {
      expect(inviteCodeFrom(code), equals(code));
    });

    test('empty string returns null', () {
      expect(inviteCodeFrom(''), isNull);
    });

    test('string with only spaces returns null', () {
      expect(inviteCodeFrom('   '), isNull);
    });

    test('non-code string returns null', () {
      expect(inviteCodeFrom('hello'), isNull);
    });

    test('code minus last character returns null', () {
      expect(inviteCodeFrom(code.substring(0, 23)), isNull);
    });

    test('code plus one extra character returns null', () {
      expect(inviteCodeFrom('${code}X'), isNull);
    });

    test('string with space inside returns null', () {
      expect(inviteCodeFrom('ab cd'), isNull);
    });

    test('24-char string containing ! returns null', () {
      expect(inviteCodeFrom('Ab3-_Zx9Qw7Lm2Kp4Rt6Yv8!'), isNull);
    });

    test('URL with short code returns null', () {
      expect(inviteCodeFrom('https://invite.sis.test/join/short'), isNull);
    });

    test('URL with no code returns null', () {
      expect(inviteCodeFrom('https://invite.sis.test/join/'), isNull);
    });

    test('two codes separated by space returns null', () {
      expect(inviteCodeFrom('$code $other'), isNull);
    });
  });

  group('inviteText', () {
    test('empty base returns code', () {
      expect(inviteText(code, ''), equals(code));
    });

    test(
      'base with path returns text starting with base and ending with code',
      () {
        const base = 'https://invite.sis.test/join/';
        final text = inviteText(code, base);
        expect(text.startsWith(base), isTrue);
        expect(text.endsWith(code), isTrue);
      },
    );

    test('round trip with base returns original code', () {
      const base = 'https://invite.sis.test/join/';
      final text = inviteText(code, base);
      expect(inviteCodeFrom(text), equals(code));
    });

    test('round trip with empty base returns original code', () {
      final text = inviteText(code, '');
      expect(inviteCodeFrom(text), equals(code));
    });

    test('round trip with hash base returns original code', () {
      const base = 'https://invite.sis.test/j#';
      final text = inviteText(code, base);
      expect(inviteCodeFrom(text), equals(code));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/invite_link.dart';

const code = 'Ab3-_Zx9Qw7Lm2Kp4Rt6Yv8N';

void main() {
  group('inviteCodeFrom trailing slash', () {
    test('bare code returns code', () {
      expect(inviteCodeFrom(code), equals(code));
    });

    test('URL with path returns code', () {
      expect(
        inviteCodeFrom('https://invite.sis.test/join/$code'),
        equals(code),
      );
    });

    test('URL with path and trailing slash returns code', () {
      expect(
        inviteCodeFrom('https://invite.sis.test/join/$code/'),
        equals(code),
      );
    });

    test(
      'URL with path, trailing slash and surrounding whitespace returns code',
      () {
        expect(
          inviteCodeFrom('  https://invite.sis.test/join/$code/\n'),
          equals(code),
        );
      },
    );

    test('URL with path, trailing slash, tab and space returns code', () {
      expect(
        inviteCodeFrom('\thttps://invite.sis.test/join/$code/ '),
        equals(code),
      );
    });

    test('URL with no code returns null', () {
      expect(inviteCodeFrom('https://invite.sis.test/join/'), isNull);
    });

    test('URL with short code returns null', () {
      expect(inviteCodeFrom('https://invite.sis.test/join/short/'), isNull);
    });

    test('code plus one extra character returns null', () {
      expect(inviteCodeFrom('${code}X/'), isNull);
    });
  });
}

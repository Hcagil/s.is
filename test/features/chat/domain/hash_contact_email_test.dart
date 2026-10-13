// hashContactEmail from its contract: SHA-256 hex of the UTF-8 bytes of
// trim().toLowerCase(); no dot or plus folding. Expected digests are the
// published SHA-256 test vectors, not values computed by the code.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/phone_book.dart';

const _empty =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  group('hashContactEmail', () {
    test('is the SHA-256 hex of the input', () {
      expect(hashContactEmail(''), _empty);
      expect(hashContactEmail('abc'), _abc);
    });

    test('lower-cases first', () {
      expect(hashContactEmail('ABC'), _abc);
    });

    test('trims first', () {
      expect(hashContactEmail(' abc\n'), _abc);
      expect(
        hashContactEmail('  Ann@MAIL.test \n'),
        hashContactEmail('ann@mail.test'),
      );
    });

    test('is always 64 lower-case hex characters', () {
      for (final e in ['X@Mail.Test', 'é@mail.test']) {
        expect(hashContactEmail(e), matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });

    test('folds no dots, pluses or inner spaces', () {
      expect(
        hashContactEmail('a.b@mail.test'),
        isNot(hashContactEmail('ab@mail.test')),
      );
      expect(
        hashContactEmail('a+1@mail.test'),
        isNot(hashContactEmail('a@mail.test')),
      );
      expect(
        hashContactEmail('a b@mail.test'),
        isNot(hashContactEmail('ab@mail.test')),
      );
    });
  });
}

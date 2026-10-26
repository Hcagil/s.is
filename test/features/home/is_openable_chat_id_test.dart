// isOpenableChatId: a notification payload opens a chat only when it has the
// shape of a real chat id, a lowercase 8-4-4-4-12 hex UUID. Written from the
// contract, never the implementation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/home/presentation/home_screen.dart';

void main() {
  const uuid = '3f2b8c1e-9a4d-4e7f-b1c2-0d9e8f7a6b5c';

  test('a lowercase UUID is openable', () {
    expect(isOpenableChatId(uuid), isTrue);
    expect(isOpenableChatId('00000000-0000-4000-8000-0000000000c1'), isTrue);
  });

  test('the same UUID in uppercase is not', () {
    expect(isOpenableChatId(uuid.toUpperCase()), isFalse);
    expect(isOpenableChatId('3F2b8c1e-9a4d-4e7f-b1c2-0d9e8f7a6b5c'), isFalse);
  });

  test('text that is not a UUID is not openable', () {
    const bad = [
      '',
      'c1',
      'does-not-exist',
      '3f2b8c1e-9a4d-4e7f-b1c2-0d9e8f7a6b5', // last group one short
      '3f2b8c1e-9a4d-4e7f-b1c2-0d9e8f7a6b5c1', // last group one long
      '3f2b8c1-9a4d-4e7f-b1c2-0d9e8f7a6b5c1', // first group one short
      '3f2b8c1e-9a4d-4e7f-b1c2-0d9e8f7a6b5g', // not hex
      '3f2b8c1e9a4d4e7fb1c20d9e8f7a6b5c', // no dashes
      '3f2b8c1e_9a4d_4e7f_b1c2_0d9e8f7a6b5c', // wrong separator
      '{3f2b8c1e-9a4d-4e7f-b1c2-0d9e8f7a6b5c}',
      ' $uuid',
      '$uuid\n',
      'x$uuid',
      '${uuid}x',
      '../$uuid',
    ];
    for (final id in bad) {
      expect(isOpenableChatId(id), isFalse, reason: 'payload "$id"');
    }
  });
}

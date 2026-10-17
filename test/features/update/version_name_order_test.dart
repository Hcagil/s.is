// isNewerVersion over year.month.change-count names (26.10.220), from the
// contract: dot-separated numbers compared part by part.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/update/domain/whats_new_note.dart';

void main() {
  group('isNewerVersion: year.month.count names', () {
    test('26.10.220 newer than 0.31.0', () {
      expect(isNewerVersion('26.10.220', '0.31.0'), isTrue);
      expect(isNewerVersion('0.31.0', '26.10.220'), isFalse);
    });

    test('26.10.221 newer than 26.10.220', () {
      expect(isNewerVersion('26.10.221', '26.10.220'), isTrue);
      expect(isNewerVersion('26.10.220', '26.10.221'), isFalse);
    });

    test('26.11.1 newer than 26.10.999', () {
      expect(isNewerVersion('26.11.1', '26.10.999'), isTrue);
      expect(isNewerVersion('26.10.999', '26.11.1'), isFalse);
    });

    test('equal names 26.10.220 vs 26.10.220', () {
      expect(isNewerVersion('26.10.220', '26.10.220'), isFalse);
      expect(isNewerVersion('26.10.220', '26.10.220'), isFalse);
    });

    test('27.1.5 newer than 26.12.900', () {
      expect(isNewerVersion('27.1.5', '26.12.900'), isTrue);
      expect(isNewerVersion('26.12.900', '27.1.5'), isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import '../support/l10n.dart';

void main() {
  group('videoPickFailed', () {
    test('English, count 1', () {
      expect(
        l10nEn.videoPickFailed(1),
        equals('This video could not be sent. Please try again.'),
      );
    });

    test('English, count 2', () {
      expect(
        l10nEn.videoPickFailed(2),
        equals('2 videos could not be sent. Please try again.'),
      );
    });

    test('English, count 5', () {
      expect(
        l10nEn.videoPickFailed(5),
        equals('5 videos could not be sent. Please try again.'),
      );
    });

    test('Turkish, count 1', () {
      expect(
        l10nTr.videoPickFailed(1),
        equals('Bu video gönderilemedi. Tekrar dene.'),
      );
    });

    test('Turkish, count 2', () {
      expect(
        l10nTr.videoPickFailed(2),
        equals('2 video gönderilemedi. Tekrar dene.'),
      );
    });

    test('Turkish, count 5', () {
      expect(
        l10nTr.videoPickFailed(5),
        equals('5 video gönderilemedi. Tekrar dene.'),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/emoji.dart';

void main() {
  group('isBigEmoji', () {
    // Basic emoji
    const smile = '\u{1F600}';
    const thumbsUp = '\u{1F44D}';
    const thumbsUpSkin = '\u{1F44D}\u{1F3FD}';
    const keycapOne = '\u{0031}\u{FE0F}\u{20E3}';

    // ZWJ family sequence
    const family = '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}';

    // Regional indicator flag pair (Turkish flag)
    const flagTurkish = '\u{1F1F9}\u{1F1F7}';
    const flagUSA = '\u{1F1FA}\u{1F1F8}';
    const flagCanada = '\u{1F1E8}\u{1F1E6}';
    const flagGermany = '\u{1F1E9}\u{1F1EA}';

    // Non‑emoji characters
    const copyright = '\u{00A9}';
    const registered = '\u{00AE}';
    const asciiDigit = '1';

    test('returns true for a single emoji', () {
      expect(isBigEmoji(smile), isTrue);
    });

    test('returns true for two emojis', () {
      expect(isBigEmoji('$smile$thumbsUp'), isTrue);
    });

    test('returns true for three emojis', () {
      expect(isBigEmoji('$smile$thumbsUp$family'), isTrue);
    });

    test('returns false for four emojis', () {
      expect(isBigEmoji('$smile$thumbsUp$family$smile'), isFalse);
    });

    test('returns true for three ZWJ family sequences', () {
      final threeFamilies = '$family$family$family';
      expect(isBigEmoji(threeFamilies), isTrue);
    });

    test('returns false for four ZWJ family sequences', () {
      final fourFamilies = '$family$family$family$family';
      expect(isBigEmoji(fourFamilies), isFalse);
    });

    test('returns true for three regional‑indicator flag pairs', () {
      final threeFlags = '$flagTurkish$flagUSA$flagCanada';
      expect(isBigEmoji(threeFlags), isTrue);
    });

    test('returns false for four regional‑indicator flag pairs', () {
      final fourFlags = '$flagTurkish$flagUSA$flagCanada$flagGermany';
      expect(isBigEmoji(fourFlags), isFalse);
    });

    test('returns true for a keycap sequence', () {
      expect(isBigEmoji(keycapOne), isTrue);
    });

    test('returns true for a keycap followed by an emoji', () {
      expect(isBigEmoji('$keycapOne$smile'), isTrue);
    });

    test('returns true for an emoji with a skin‑tone modifier', () {
      expect(isBigEmoji(thumbsUpSkin), isTrue);
    });

    test('returns true for a skin‑tone emoji followed by another emoji', () {
      expect(isBigEmoji('$thumbsUpSkin$smile'), isTrue);
    });

    test('returns false for a bare ASCII digit', () {
      expect(isBigEmoji(asciiDigit), isFalse);
    });

    test('returns false for © and ® characters', () {
      expect(isBigEmoji(copyright), isFalse);
      expect(isBigEmoji(registered), isFalse);
    });

    test('returns false for empty string', () {
      expect(isBigEmoji(''), isFalse);
    });

    test('returns false for whitespace‑only string', () {
      expect(isBigEmoji('   \n  '), isFalse);
    });

    test('returns true for whitespace‑separated emojis', () {
      final spaced = '$smile  $thumbsUp';
      expect(isBigEmoji(spaced), isTrue);
    });

    test('returns true for emojis separated by newlines', () {
      final newlineSeparated = '$smile\n$thumbsUp';
      expect(isBigEmoji(newlineSeparated), isTrue);
    });

    test('returns true for emojis with leading/trailing newlines', () {
      final withNewlines = '\n$smile\n';
      expect(isBigEmoji(withNewlines), isTrue);
    });

    test('four skin-toned or keycap emoji are four, not eight', () {
      expect(isBigEmoji('$thumbsUpSkin$thumbsUpSkin$thumbsUpSkin'), isTrue);
      expect(
        isBigEmoji('$thumbsUpSkin$thumbsUpSkin$thumbsUpSkin$thumbsUpSkin'),
        isFalse,
      );
      expect(isBigEmoji('$keycapOne$keycapOne$keycapOne'), isTrue);
      expect(isBigEmoji('$keycapOne$keycapOne$keycapOne$keycapOne'), isFalse);
    });

    test('digits and (c)/(r) beside an emoji make it text', () {
      expect(isBigEmoji('1$smile'), isFalse);
      expect(isBigEmoji('$copyright$smile'), isFalse);
      expect(isBigEmoji('$smile$registered'), isFalse);
    });

    test('returns false for mixed text and emoji', () {
      expect(isBigEmoji('$smile!'), isFalse);
      expect(isBigEmoji('ok$smile'), isFalse);
      expect(isBigEmoji('Hello $smile'), isFalse);
    });

    test('boundary: three emojis with whitespace is true', () {
      final threeWithSpace = '$smile \n $thumbsUp \n $family';
      expect(isBigEmoji(threeWithSpace), isTrue);
    });

    test('boundary: four emojis with whitespace is false', () {
      final fourWithSpace = '$smile \n $thumbsUp \n $family \n $smile';
      expect(isBigEmoji(fourWithSpace), isFalse);
    });
  });
}

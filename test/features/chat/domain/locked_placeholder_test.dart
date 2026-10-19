// isLockedPlaceholder (Private Chats 4a Group C): true only for the exact
// placeholder text. Drafted by test_writer from the contract, judged by qa.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';

void main() {
  test('returns true for lockedBodyPlaceholder', () {
    expect(isLockedPlaceholder(lockedBodyPlaceholder), isTrue);
  });

  test('returns false for empty string', () {
    expect(isLockedPlaceholder(''), isFalse);
  });

  test('returns false for placeholder with surrounding spaces', () {
    expect(isLockedPlaceholder(' $lockedBodyPlaceholder'), isFalse);
    expect(isLockedPlaceholder('$lockedBodyPlaceholder '), isFalse);
  });

  test('returns false for placeholder without lock emoji', () {
    expect(isLockedPlaceholder('Encrypted message'), isFalse);
  });

  test('returns false for lower case placeholder', () {
    expect(isLockedPlaceholder('🔒 encrypted message'), isFalse);
  });

  test('returns false for longer text containing placeholder', () {
    expect(isLockedPlaceholder('🔒 Encrypted message is hidden'), isFalse);
  });
}

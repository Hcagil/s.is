// The delete-for-everyone vanish rule, from the contract: own and under 15 minutes.
// Boundary is strict: 14:59 vanishes, 15:00 leaves a placeholder.

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  final now = DateTime.utc(2026, 3, 1, 12, 0);
  group('deletionOnDelete', () {
    test('the window is 15 minutes', () {
      expect(vanishWindow, const Duration(minutes: 15));
    });

    test('own message at 0s -> vanished', () {
      expect(
        deletionOnDelete(ownMessage: true, createdAt: now, now: now),
        MessageDeletion.vanished,
      );
    });

    test('own message at 14m59s -> vanished', () {
      expect(
        deletionOnDelete(
          ownMessage: true,
          createdAt: now.subtract(const Duration(minutes: 14, seconds: 59)),
          now: now,
        ),
        MessageDeletion.vanished,
      );
    });

    test('own message at exactly 15m -> placeholder', () {
      expect(
        deletionOnDelete(
          ownMessage: true,
          createdAt: now.subtract(const Duration(minutes: 15)),
          now: now,
        ),
        MessageDeletion.placeholder,
      );
    });

    test('own message at 15m01s -> placeholder', () {
      expect(
        deletionOnDelete(
          ownMessage: true,
          createdAt: now.subtract(const Duration(minutes: 15, seconds: 1)),
          now: now,
        ),
        MessageDeletion.placeholder,
      );
    });

    test('own message 2 days old -> placeholder', () {
      expect(
        deletionOnDelete(
          ownMessage: true,
          createdAt: now.subtract(const Duration(days: 2)),
          now: now,
        ),
        MessageDeletion.placeholder,
      );
    });

    test('not own message at 0s -> placeholder', () {
      expect(
        deletionOnDelete(ownMessage: false, createdAt: now, now: now),
        MessageDeletion.placeholder,
      );
    });

    test('not own message at 1m -> placeholder', () {
      expect(
        deletionOnDelete(
          ownMessage: false,
          createdAt: now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        MessageDeletion.placeholder,
      );
    });

    test('not own message at 14m59s -> placeholder', () {
      expect(
        deletionOnDelete(
          ownMessage: false,
          createdAt: now.subtract(const Duration(minutes: 14, seconds: 59)),
          now: now,
        ),
        MessageDeletion.placeholder,
      );
    });

    test('own message with createdAt slightly in the future -> vanished', () {
      expect(
        deletionOnDelete(
          ownMessage: true,
          createdAt: now.add(const Duration(minutes: 1)),
          now: now,
        ),
        MessageDeletion.vanished,
      );
    });
  });
}

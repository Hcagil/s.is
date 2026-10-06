// Unit tests for the pure read-status domain: ReadMark.hasRead. Written from the contract in read_marks.dart's own doc
// comments, never from how any repository or controller uses them.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/read_marks.dart';

void main() {
  final sentAt = DateTime(2026, 9, 25, 12);

  group('ReadMark.hasRead', () {
    test('not shared: not read', () {
      const mark = ReadMark(userId: 'u2', shares: false);
      expect(mark.hasRead(sentAt), isFalse);
    });

    test('shared but never read (readAt null): not read', () {
      const mark = ReadMark(userId: 'u2', shares: true, readAt: null);
      expect(mark.hasRead(sentAt), isFalse);
    });

    test('shared, read strictly before the message was sent: not read', () {
      final mark = ReadMark(
        userId: 'u2',
        shares: true,
        readAt: sentAt.subtract(const Duration(seconds: 1)),
      );
      expect(mark.hasRead(sentAt), isFalse);
    });

    test('shared, read at EXACTLY the moment it was sent: counts as read', () {
      final mark = ReadMark(userId: 'u2', shares: true, readAt: sentAt);
      expect(
        mark.hasRead(sentAt),
        isTrue,
        reason:
            'the edge: readAt == sentAt must count, not only strictly '
            'after -- otherwise a member who reads the instant a message '
            'arrives never shows as caught up',
      );
    });

    test('shared, read after it was sent: read', () {
      final mark = ReadMark(
        userId: 'u2',
        shares: true,
        readAt: sentAt.add(const Duration(minutes: 1)),
      );
      expect(mark.hasRead(sentAt), isTrue);
    });
  });

  test('compares instants, not wall clocks: a UTC read a minute after a '
      'local send is read (run under TZ=JST-9)', () {
    final local = DateTime(2026, 9, 25, 12);
    final readUtc = local.toUtc().add(const Duration(minutes: 1));
    expect(
      ReadMark(userId: 'u2', shares: true, readAt: readUtc).hasRead(local),
      isTrue,
    );
    expect(
      ReadMark(
        userId: 'u2',
        shares: true,
        readAt: local.toUtc().subtract(const Duration(minutes: 1)),
      ).hasRead(local),
      isFalse,
    );
  });
  // isReadByAnyone (one reader is enough) is gone with the ticks: the
  // every-recipient rules live in domain/delivery_marks_test.dart.
}

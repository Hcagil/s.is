// Unit tests for the pure read-status domain: ReadMark.hasRead and
// isReadByAll. Written from the contract in read_marks.dart's own doc
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

  group('isReadByAll', () {
    test('nobody shares: vacuously read -- the message looks normal', () {
      final marks = [
        ReadMark(userId: 'u2', shares: false, readAt: null),
        ReadMark(userId: 'u3', shares: false, readAt: null),
      ];
      expect(
        isReadByAll(marks, sentAt),
        isTrue,
        reason:
            'nothing to show when nobody shares -- must not read as '
            'unread forever',
      );
    });

    test('no marks at all (e.g. a 1:1 where the other never shared): read', () {
      expect(isReadByAll(const [], sentAt), isTrue);
    });

    test('one sharing member has read, one has not: not read', () {
      final marks = [
        ReadMark(
          userId: 'u2',
          shares: true,
          readAt: sentAt.add(const Duration(minutes: 1)),
        ),
        const ReadMark(userId: 'u3', shares: true, readAt: null),
      ];
      expect(isReadByAll(marks, sentAt), isFalse);
    });

    test('a non-sharing member with no readAt is ignored -- '
        'only sharing members gate the answer', () {
      final marks = [
        ReadMark(
          userId: 'u2',
          shares: true,
          readAt: sentAt.add(const Duration(minutes: 1)),
        ),
        const ReadMark(userId: 'u3', shares: false, readAt: null),
      ];
      expect(
        isReadByAll(marks, sentAt),
        isTrue,
        reason: 'u3 does not share, so u3 cannot block the read indicator',
      );
    });

    test('every sharing member has read: read', () {
      final marks = [
        ReadMark(
          userId: 'u2',
          shares: true,
          readAt: sentAt.add(const Duration(minutes: 1)),
        ),
        ReadMark(userId: 'u3', shares: true, readAt: sentAt),
      ];
      expect(isReadByAll(marks, sentAt), isTrue);
    });
  });
}

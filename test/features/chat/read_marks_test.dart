// Unit tests for the pure read-status domain: ReadMark.hasRead and
// isReadByAnyone. Written from the contract in read_marks.dart's own doc
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

  group('isReadByAnyone', () {
    ReadMark readBy(String id) => ReadMark(
      userId: id,
      shares: true,
      readAt: sentAt.add(const Duration(minutes: 1)),
    );
    ReadMark unreadBy(String id) => ReadMark(
      userId: id,
      shares: true,
      readAt: sentAt.subtract(const Duration(minutes: 1)),
    );

    test(
      'nobody shares: read -- nothing to show, the message looks normal',
      () {
        final marks = [
          const ReadMark(userId: 'u2', shares: false),
          const ReadMark(userId: 'u3', shares: false),
        ];
        expect(
          isReadByAnyone(marks, sentAt),
          isTrue,
          reason:
              'nothing to show when nobody shares -- must not read as '
              'unread forever',
        );
      },
    );

    test('no marks at all (e.g. a 1:1 where the other never shared): read', () {
      expect(isReadByAnyone(const [], sentAt), isTrue);
    });

    test('1:1: the one sharer has not read it: not read', () {
      expect(isReadByAnyone([unreadBy('u2')], sentAt), isFalse);
      expect(
        isReadByAnyone(const [ReadMark(userId: 'u2', shares: true)], sentAt),
        isFalse,
      );
    });

    test('1:1: the one sharer has read it: read', () {
      expect(isReadByAnyone([readBy('u2')], sentAt), isTrue);
    });

    test('group: one sharer has read, one has not: read -- one reader is '
        'enough', () {
      expect(isReadByAnyone([readBy('u2'), unreadBy('u3')], sentAt), isTrue);
      expect(isReadByAnyone([unreadBy('u2'), readBy('u3')], sentAt), isTrue);
    });

    test('group: one of several sharers has read: read', () {
      final marks = [
        unreadBy('u2'),
        unreadBy('u3'),
        readBy('u4'),
        unreadBy('u5'),
      ];
      expect(isReadByAnyone(marks, sentAt), isTrue);
    });

    test('group: several sharers, none has read: not read', () {
      final marks = [
        unreadBy('u2'),
        const ReadMark(userId: 'u3', shares: true),
        unreadBy('u4'),
      ];
      expect(isReadByAnyone(marks, sentAt), isFalse);
    });

    test('every sharer has read: read', () {
      expect(isReadByAnyone([readBy('u2'), readBy('u3')], sentAt), isTrue);
    });

    test('a non-sharing member never counts as the reader', () {
      // u3 does not share; whatever readAt it carries is not a read.
      final marks = [
        unreadBy('u2'),
        ReadMark(
          userId: 'u3',
          shares: false,
          readAt: sentAt.add(const Duration(minutes: 1)),
        ),
      ];
      expect(isReadByAnyone(marks, sentAt), isFalse);
    });

    test('a non-sharing member does not make a sharer\'s silence '
        '"nobody shares"', () {
      final marks = [
        unreadBy('u2'),
        const ReadMark(userId: 'u3', shares: false),
      ];
      expect(isReadByAnyone(marks, sentAt), isFalse);
    });

    test('a sharer who read at exactly the send time counts', () {
      final marks = [
        unreadBy('u2'),
        ReadMark(userId: 'u3', shares: true, readAt: sentAt),
      ];
      expect(isReadByAnyone(marks, sentAt), isTrue);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  group('isSendableBody mirrors the database constraint', () {
    test('rejects empty and whitespace-only bodies', () {
      expect(isSendableBody(''), isFalse);
      expect(isSendableBody('   '), isFalse);
      expect(isSendableBody('\n\t '), isFalse);
    });

    test('accepts a body with content, including surrounding space', () {
      expect(isSendableBody('hi'), isTrue);
      expect(isSendableBody('  hi  '), isTrue);
    });

    test('measures length after trimming, like btrim in the constraint', () {
      final exact = 'a' * maxMessageLength;
      expect(isSendableBody(exact), isTrue);
      expect(isSendableBody('  $exact  '), isTrue);
      expect(isSendableBody('a$exact'), isFalse);
    });
  });

  test('isFrom decides which side a message is drawn on', () {
    final m = Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'me',
      body: 'hello',
      createdAt: DateTime.utc(2026, 9, 22),
    );
    expect(m.isFrom('me'), isTrue);
    expect(m.isFrom('someone-else'), isFalse);
  });

  group('previewText', () {
    Message m({String body = '', String? path}) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'u1',
      body: body,
      createdAt: DateTime.utc(2026, 9, 22),
      attachmentPath: path,
    );

    test('a text message previews as its body', () {
      expect(previewText(m(body: 'see you')), 'see you');
    });

    test('an image with no caption previews as Photo', () {
      expect(previewText(m(path: 'c1/1.png')), 'Photo');
    });

    test('an image with a caption previews as the caption', () {
      expect(previewText(m(body: 'look', path: 'c1/1.png')), 'look');
    });
  });

  group('previewTime', () {
    // Built from local wall-clock values, so every expectation below holds in
    // any time zone the suite runs in. The two local-time tests can only tell
    // local from UTC where they differ: the container defaults to UTC, so run
    // them with `docker compose run --rm -e TZ=JST-9 flutter flutter test ...`
    // (a POSIX zone string; the image has no tzdata) to make them bite.
    final now = DateTime(2026, 9, 23, 15, 40);

    test('today shows the time of day, zero-padded', () {
      expect(previewTime(DateTime(2026, 9, 23, 9, 5), now), '09:05');
    });

    test('another day shows the date as dd.MM.yy', () {
      expect(previewTime(DateTime(2026, 9, 3, 9, 5), now), '03.09.26');
    });

    test('the same day and month of another year is not today', () {
      expect(previewTime(DateTime(2025, 9, 23, 9, 5), now), '23.09.25');
    });

    test('the same day of another month is not today', () {
      expect(previewTime(DateTime(2026, 8, 23, 9, 5), now), '23.08.26');
    });

    test('midnight is the boundary between the two formats', () {
      final justAfterMidnight = DateTime(2026, 9, 23, 0, 0, 30);
      expect(
        previewTime(DateTime(2026, 9, 22, 23, 59, 59), justAfterMidnight),
        '22.09.26',
        reason: 'one second before midnight is yesterday',
      );
      expect(previewTime(DateTime(2026, 9, 23), justAfterMidnight), '00:00');
      expect(
        previewTime(DateTime(2026, 9, 23, 23, 59), DateTime(2026, 9, 23)),
        '23:59',
        reason: 'the last minute of today is still today',
      );
    });

    test('a UTC timestamp is shown in local time', () {
      // Timestamps arrive from the server in UTC. The same instant, handed
      // over as UTC, must render exactly like its local form.
      final local = DateTime(2026, 9, 23, 9, 5);
      expect(previewTime(local.toUtc(), now), '09:05');
      expect(previewTime(local.toUtc(), now.toUtc()), '09:05');
    });

    test('"today" is decided in local time, not in UTC', () {
      // Local 00:30 and local 23:30 on the same local day. Wherever the zone
      // is not UTC, one of them falls on a different UTC date; a comparison
      // made in UTC then calls today's message yesterday's.
      final early = DateTime(2026, 9, 23, 0, 30);
      final late = DateTime(2026, 9, 23, 23, 30);
      expect(previewTime(early.toUtc(), late.toUtc()), '00:30');
      expect(previewTime(late.toUtc(), early.toUtc()), '23:30');
    });
  });

  test('withPreview replaces the preview and keeps who the chat is with', () {
    const bob = Member(userId: 'u2', displayName: 'Bob');
    const before = Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'old',
      lastMessageAt: null,
      lastSenderId: 'u1',
    );
    final at = DateTime.utc(2026, 9, 22, 12);
    final after = before.withPreview(
      Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u2',
        body: 'new',
        createdAt: at,
      ),
    );
    expect(after.id, 'c1');
    expect(after.other, bob);
    expect(after.title, isNull);
    expect(after.lastMessage, 'new');
    expect(after.lastMessageAt, at);
    expect(after.lastSenderId, 'u2');

    const group = Conversation(id: 'g1', title: 'Trip');
    final photo = group.withPreview(
      Message(
        id: 'm3',
        conversationId: 'g1',
        senderId: 'u2',
        body: '',
        createdAt: at,
        attachmentPath: 'g1/1.png',
      ),
    );
    expect(photo.title, 'Trip');
    expect(
      photo.lastMessage,
      'Photo',
      reason: 'a live image must preview like a re-read one, not as blank',
    );
  });
}

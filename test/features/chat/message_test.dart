import 'package:flutter_test/flutter_test.dart';
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
}

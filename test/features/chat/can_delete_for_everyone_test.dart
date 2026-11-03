// Message.canDeleteForEveryone (delete rules 2 and 4): own message under 6 h,
// a group admin any message at any age; never pending or deleted. TZ=JST-9.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

final _now = DateTime.utc(2026, 9, 24, 12);

Message msg({
  String sender = 'me',
  Duration age = const Duration(minutes: 1),
  Uint8List? localImage,
  String? attachmentPath,
  MessageDeletion? deletion,
  bool sending = false,
}) {
  return Message(
    id: 'm1',
    conversationId: 'c1',
    senderId: sender,
    body: 'hi',
    createdAt: _now.subtract(age),
    localImage: localImage,
    attachmentPath: attachmentPath,
    deletion: deletion,
    sending: sending,
  );
}

void main() {
  group('Message.canDeleteForEveryone', () {
    test('1. own, age 1 min -> true', () {
      expect(msg().canDeleteForEveryone('me', now: _now), isTrue);
    });

    test('2. own, age 5h59m59s -> true', () {
      final age = const Duration(hours: 5, minutes: 59, seconds: 59);
      expect(msg(age: age).canDeleteForEveryone('me', now: _now), isTrue);
    });

    test('3. own, age exactly 6 h -> false', () {
      final age = const Duration(hours: 6);
      expect(msg(age: age).canDeleteForEveryone('me', now: _now), isFalse);
    });

    test('4. own, age 6h + 1s -> false; age 400 days -> false', () {
      expect(
        msg(age: const Duration(hours: 6, seconds: 1))
            .canDeleteForEveryone('me', now: _now),
        isFalse,
      );
      expect(
        msg(age: const Duration(days: 400))
            .canDeleteForEveryone('me', now: _now),
        isFalse,
      );
    });

    test('5. other\'s message age 1 min, admin false -> false', () {
      expect(
        msg(sender: 'other').canDeleteForEveryone('me', now: _now),
        isFalse,
      );
    });

    test('6. other\'s message age 30 days, admin true -> true; own 7 h old with admin true -> true', () {
      expect(
        msg(
          sender: 'other',
          age: const Duration(days: 30),
        ).canDeleteForEveryone('me', now: _now, admin: true),
        isTrue,
      );
      expect(
        msg(age: const Duration(hours: 7))
            .canDeleteForEveryone('me', now: _now, admin: true),
        isTrue,
      );
    });

    test(
      '7. every MessageDeletion value: false for own fresh and for admin',
      () {
        for (final del in MessageDeletion.values) {
          expect(
            msg(deletion: del).canDeleteForEveryone('me', now: _now),
            isFalse,
          );
          expect(
            msg(deletion: del)
                .canDeleteForEveryone('me', now: _now, admin: true),
            isFalse,
          );
        }
      },
    );

    test(
      '8. pending (sending: true) and pending photo -> false even with admin',
      () {
        expect(
          msg(sending: true).canDeleteForEveryone('me', now: _now, admin: true),
          isFalse,
        );
        expect(
          msg(localImage: Uint8List(0))
              .canDeleteForEveryone('me', now: _now, admin: true),
          isFalse,
        );
      },
    );

    test('9. stored photo (localImage + attachmentPath) age 1 min -> true', () {
      expect(
        msg(
          localImage: Uint8List(0),
          attachmentPath: 'c1/1.png',
        ).canDeleteForEveryone('me', now: _now),
        isTrue,
      );
    });

    test('10. the now argument decides', () {
      final baseMsg = msg(age: const Duration(hours: 1));
      expect(baseMsg.canDeleteForEveryone('me', now: _now), isTrue);
      expect(
        baseMsg.canDeleteForEveryone(
          'me',
          now: _now.add(const Duration(hours: 5, minutes: 1)),
        ),
        isFalse,
      );
    });

    test('11. local vs UTC', () {
      final localCreated = _now
          .subtract(const Duration(hours: 5, minutes: 59))
          .toLocal();
      final msgLocal = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'me',
        body: 'hi',
        createdAt: localCreated,
      );
      expect(msgLocal.canDeleteForEveryone('me', now: _now.toLocal()), isTrue);

      final localCreated2 = _now
          .subtract(const Duration(hours: 6, minutes: 1))
          .toLocal();
      final msgLocal2 = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'me',
        body: 'hi',
        createdAt: localCreated2,
      );
      expect(
        msgLocal2.canDeleteForEveryone('me', now: _now.toLocal()),
        isFalse,
      );
    });
  });
}

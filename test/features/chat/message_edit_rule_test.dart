import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

/// Helper that builds a baseline message with sensible defaults.
/// Any parameter can be overridden to create a specific test case.
Message msg({
  String? id,
  String? conversationId,
  String? senderId,
  String? body,
  DateTime? createdAt,
  String? attachmentPath,
  Uint8List? attachmentPreview,
  Uint8List? localImage,
  MessageDeletion? deletion,
  DateTime? editedAt,
  String? replyTo,
  bool? forwarded,
}) {
  final defaultNow = DateTime.utc(2026, 9, 25, 10, 0, 0);
  return Message(
    id: id ?? 'id',
    conversationId: conversationId ?? 'conv',
    senderId: senderId ?? 'me',
    body: body ?? 'Hello',
    createdAt: createdAt ?? defaultNow.subtract(const Duration(minutes: 1)),
    attachmentPath: attachmentPath,
    attachmentPreview: attachmentPreview,
    localImage: localImage,
    deletion: deletion,
    editedAt: editedAt,
    replyTo: replyTo,
    forwarded: forwarded ?? false,
  );
}

void main() {
  const me = 'user1';
  final now = DateTime.utc(2026, 9, 25, 10, 0, 0);

  group('Message.canEdit', () {
    test('own fresh text message', () {
      final message = msg(
        senderId: me,
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isTrue);
    });

    test('own photo message (attachmentPath set, empty body)', () {
      final message = msg(
        senderId: me,
        body: '',
        attachmentPath: 'path/to/photo.jpg',
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isTrue);
    });

    test('someone else\'s message', () {
      final message = msg(
        senderId: 'other',
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('deleted message (vanished)', () {
      final message = msg(
        senderId: me,
        deletion: MessageDeletion.vanished,
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('deleted message (placeholder)', () {
      final message = msg(
        senderId: me,
        deletion: MessageDeletion.placeholder,
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('forwarded message', () {
      final message = msg(
        senderId: me,
        forwarded: true,
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('pending photo upload', () {
      final message = msg(
        senderId: me,
        localImage: Uint8List.fromList([0]),
        attachmentPath: null,
        createdAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('age boundary: 5h59m59s', () {
      final message = msg(
        senderId: me,
        createdAt: now.subtract(
          const Duration(hours: 5, minutes: 59, seconds: 59),
        ),
      );
      expect(message.canEdit(me, now), isTrue);
    });

    test('age boundary: exactly 6h', () {
      final message = msg(
        senderId: me,
        createdAt: now.subtract(const Duration(hours: 6)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('age boundary: 6h + 1 microsecond', () {
      final message = msg(
        senderId: me,
        createdAt: now
            .subtract(const Duration(hours: 6))
            .subtract(const Duration(microseconds: 1)),
      );
      expect(message.canEdit(me, now), isFalse);
    });

    test('already edited message remains editable', () {
      final message = msg(
        senderId: me,
        editedAt: now.subtract(const Duration(minutes: 5)),
        createdAt: now.subtract(const Duration(minutes: 10)),
      );
      expect(message.canEdit(me, now), isTrue);
    });
  });

  group('Message.isEdited', () {
    test('editedAt null -> false', () {
      final message = msg(editedAt: null);
      expect(message.isEdited, isFalse);
    });

    test('editedAt set -> true', () {
      final message = msg(editedAt: now.subtract(const Duration(minutes: 5)));
      expect(message.isEdited, isTrue);
    });
  });

  group('Timezone handling', () {
    test('createdAt UTC, now local 1 hour later -> true', () {
      final createdAt = DateTime.utc(2026, 9, 25, 5, 32);
      final nowLocal = createdAt.add(const Duration(hours: 1)).toLocal();
      final message = msg(senderId: me, createdAt: createdAt);
      expect(message.canEdit(me, nowLocal), isTrue);
    });

    test('createdAt UTC, now local 7 hours later -> false', () {
      final createdAt = DateTime.utc(2026, 9, 25, 5, 32);
      final nowLocal = createdAt.add(const Duration(hours: 7)).toLocal();
      final message = msg(senderId: me, createdAt: createdAt);
      expect(message.canEdit(me, nowLocal), isFalse);
    });
  });
}

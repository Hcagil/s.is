// Message.withLocalImage, from its contract: a copy carrying the given bytes
// as its local image, every other field kept, the original untouched.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  group('Message.withLocalImage', () {
    // Common data used across tests
    final previewBytes = Uint8List.fromList([10, 20, 30]);
    final localBytes = Uint8List.fromList([1, 2, 3]);
    final now = DateTime.now();
    final editedAt = now.subtract(const Duration(minutes: 5));

    // A fully populated message used as a baseline
    final baseline = Message(
      id: 'msg1',
      conversationId: 'conv1',
      senderId: 'user1',
      body: 'Hello',
      createdAt: now,
      attachmentPath: 'path/to/file',
      attachmentPreview: previewBytes,
      localImage: null,
      deletion: MessageDeletion.placeholder,
      deletedBy: 'user2',
      editedAt: editedAt,
      replyTo: 'msg0',
      forwarded: true,
      sending: true,
    );

    test(
      'returns a copy with updated localImage and all other fields unchanged',
      () {
        final updated = baseline.withLocalImage(localBytes);

        // The new instance should not be the same object
        expect(identical(updated, baseline), isFalse);

        // All fields except localImage should be identical
        expect(updated.id, equals(baseline.id));
        expect(updated.conversationId, equals(baseline.conversationId));
        expect(updated.senderId, equals(baseline.senderId));
        expect(updated.body, equals(baseline.body));
        expect(updated.createdAt, equals(baseline.createdAt));
        expect(updated.attachmentPath, equals(baseline.attachmentPath));
        expect(updated.attachmentPreview, equals(baseline.attachmentPreview));
        expect(updated.deletion, equals(baseline.deletion));
        expect(updated.deletedBy, equals(baseline.deletedBy));
        expect(updated.editedAt, equals(baseline.editedAt));
        expect(updated.replyTo, equals(baseline.replyTo));
        expect(updated.forwarded, equals(baseline.forwarded));
        expect(updated.sending, equals(baseline.sending));

        // localImage should be the new bytes (identical reference)
        expect(identical(updated.localImage, localBytes), isTrue);

        // The original message remains unchanged
        expect(baseline.localImage, isNull);
      },
    );

    test('passing null clears localImage', () {
      // Start with a message that already has a local image
      final withLocal = baseline.withLocalImage(localBytes);
      expect(withLocal.localImage, isNotNull);

      final cleared = withLocal.withLocalImage(null);
      expect(cleared.localImage, isNull);

      // All other fields should remain unchanged
      expect(cleared.id, equals(withLocal.id));
      expect(cleared.conversationId, equals(withLocal.conversationId));
      expect(cleared.senderId, equals(withLocal.senderId));
      expect(cleared.body, equals(withLocal.body));
      expect(cleared.createdAt, equals(withLocal.createdAt));
      expect(cleared.attachmentPath, equals(withLocal.attachmentPath));
      expect(cleared.attachmentPreview, equals(withLocal.attachmentPreview));
      expect(cleared.deletion, equals(withLocal.deletion));
      expect(cleared.deletedBy, equals(withLocal.deletedBy));
      expect(cleared.editedAt, equals(withLocal.editedAt));
      expect(cleared.replyTo, equals(withLocal.replyTo));
      expect(cleared.forwarded, equals(withLocal.forwarded));
      expect(cleared.sending, equals(withLocal.sending));
    });

    test('isPending is false when attachmentPath is set, sending is false, and localImage is set', () {
      final msg = Message(
        id: 'msg2',
        conversationId: 'conv2',
        senderId: 'user3',
        body: 'Test',
        createdAt: now,
        attachmentPath: 'path/to/file',
        attachmentPreview: previewBytes,
        localImage: null,
        deletion: null,
        deletedBy: null,
        editedAt: null,
        replyTo: null,
        forwarded: false,
        sending: false,
      );

      final updated = msg.withLocalImage(localBytes);
      expect(updated.isPending, isFalse);
    });

    test('isPending is true when attachmentPath is null, sending is false, and localImage is set', () {
      final msg = Message(
        id: 'msg3',
        conversationId: 'conv3',
        senderId: 'user4',
        body: 'Another test',
        createdAt: now,
        attachmentPath: null,
        attachmentPreview: previewBytes,
        localImage: null,
        deletion: null,
        deletedBy: null,
        editedAt: null,
        replyTo: null,
        forwarded: false,
        sending: false,
      );

      final updated = msg.withLocalImage(localBytes);
      expect(updated.isPending, isTrue);
    });

    test('forwarded and sending flags are preserved', () {
      final msg = Message(
        id: 'msg4',
        conversationId: 'conv4',
        senderId: 'user5',
        body: 'Forwarded message',
        createdAt: now,
        attachmentPath: null,
        attachmentPreview: previewBytes,
        localImage: null,
        deletion: null,
        deletedBy: null,
        editedAt: null,
        replyTo: null,
        forwarded: true,
        sending: true,
      );

      final updated = msg.withLocalImage(localBytes);
      expect(updated.forwarded, isTrue);
      expect(updated.sending, isTrue);
    });

    test('deletion, deletedBy, editedAt, replyTo, and attachmentPreview are preserved', () {
      final msg = Message(
        id: 'msg5',
        conversationId: 'conv5',
        senderId: 'user6',
        body: 'Deletion test',
        createdAt: now,
        attachmentPath: null,
        attachmentPreview: previewBytes,
        localImage: null,
        deletion: MessageDeletion.vanished,
        deletedBy: 'user7',
        editedAt: editedAt,
        replyTo: 'msg10',
        forwarded: false,
        sending: false,
      );

      final updated = msg.withLocalImage(localBytes);
      expect(updated.deletion, equals(msg.deletion));
      expect(updated.deletedBy, equals(msg.deletedBy));
      expect(updated.editedAt, equals(msg.editedAt));
      expect(updated.replyTo, equals(msg.replyTo));
      expect(updated.attachmentPreview, equals(msg.attachmentPreview));
    });
  });
}

// Message.isPendingOf, from its 0.30.11 contract: a pending photo (local bytes,
// no stored path) is the one a stored row stands for when the captions are
// equal and, if both carry a preview, the preview bytes are equal. With either
// preview missing it matches on caption alone (the documented ceiling).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

Message pending({
  String body = 'beach',
  Uint8List? preview,
  Uint8List? local,
  String? path,
}) => Message(
  id: 'local-1',
  conversationId: 'c1',
  senderId: 'u1',
  body: body,
  createdAt: DateTime(2026, 10, 3),
  attachmentPath: path,
  attachmentPreview: preview,
  localImage: local ?? bytes([9, 9, 9]),
);

Message stored({String body = 'beach', Uint8List? preview, Uint8List? local}) =>
    Message(
      id: 'img-1',
      conversationId: 'c1',
      senderId: 'u1',
      body: body,
      createdAt: DateTime(2026, 10, 3),
      attachmentPath: 'c1/1.jpg',
      attachmentPreview: preview,
      localImage: local,
    );

void main() {
  test('equal captions and equal preview bytes (distinct buffers) match', () {
    expect(
      pending(preview: bytes([1, 2, 3]))
          .isPendingOf(stored(preview: bytes([1, 2, 3]))),
      isTrue,
    );
  });

  test('equal captions but different preview bytes do not match', () {
    expect(
      pending(preview: bytes([1, 2, 3]))
          .isPendingOf(stored(preview: bytes([1, 2, 4]))),
      isFalse,
    );
    expect(
      pending(preview: bytes([1, 2, 3]))
          .isPendingOf(stored(preview: bytes([1, 2, 3, 4]))),
      isFalse,
      reason: 'a longer preview with the same prefix is another photo',
    );
  });

  test('different captions never match, even with equal previews', () {
    expect(
      pending(
        body: 'beach',
        preview: bytes([1]),
      ).isPendingOf(stored(body: 'sea', preview: bytes([1]))),
      isFalse,
    );
    expect(pending(body: 'beach').isPendingOf(stored(body: 'sea')), isFalse);
  });

  test('one preview missing: matches on caption alone', () {
    expect(pending(preview: bytes([1])).isPendingOf(stored()), isTrue);
    expect(pending().isPendingOf(stored(preview: bytes([1]))), isTrue);
    expect(
      pending(body: 'a', preview: bytes([1])).isPendingOf(stored(body: 'b')),
      isFalse,
    );
  });

  test('both previews missing: matches on caption alone', () {
    expect(pending().isPendingOf(stored()), isTrue);
    expect(pending(body: 'a').isPendingOf(stored(body: 'b')), isFalse);
  });

  test('this must be pending: no local bytes means no match', () {
    final noLocal = Message(
      id: 'x',
      conversationId: 'c1',
      senderId: 'u1',
      body: 'beach',
      createdAt: DateTime(2026, 10, 3),
      attachmentPreview: bytes([1]),
    );
    expect(noLocal.isPendingOf(stored(preview: bytes([1]))), isFalse);
  });

  test('this must be pending: an entry already stored (has a path) never '
      'matches, even keeping its local bytes', () {
    expect(
      pending(
        path: 'c1/0.jpg',
        preview: bytes([1]),
      ).isPendingOf(stored(preview: bytes([1]))),
      isFalse,
    );
  });

  test('the stored side\'s own local bytes or path state do not decide it', () {
    // Only this (the receiver) carries the pending preconditions.
    expect(
      pending(preview: bytes([1]))
          .isPendingOf(stored(preview: bytes([1]), local: bytes([7]))),
      isTrue,
    );
  });
}

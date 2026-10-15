import 'dart:typed_data';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/album_layout.dart';

void main() {
  group('PickedImage', () {
    test('inGroup returns new instance with updated photoGroup', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final preview = Uint8List.fromList([4, 5]);
      final original = PickedImage(
        bytes: bytes,
        contentType: 'image/png',
        extension: 'png',
        preview: preview,
        photoGroup: 'g1',
      );

      final newImage = original.inGroup('g2');

      expect(newImage.photoGroup, equals('g2'));
      expect(newImage.bytes, same(bytes));
      expect(newImage.contentType, equals(original.contentType));
      expect(newImage.extension, equals(original.extension));
      expect(newImage.preview, same(preview));
      // original unchanged
      expect(original.photoGroup, equals('g1'));
    });
  });

  group('Message', () {
    test('withPhotoGroup updates photoGroup only', () {
      final original = Message(
        id: 'id',
        conversationId: 'conv',
        senderId: 'sender',
        body: 'body',
        createdAt: DateTime(2023, 1, 1),
        attachmentPath: 'path',
        attachmentPreview: Uint8List.fromList([10, 20]),
        localImage: Uint8List.fromList([30, 40]),
        replyTo: 'reply',
        forwarded: true,
        sending: true,
        photoGroup: 'g1',
      );

      final updated = original.withPhotoGroup('g2');

      expect(updated.photoGroup, equals('g2'));
      expect(updated.id, equals(original.id));
      expect(updated.conversationId, equals(original.conversationId));
      expect(updated.senderId, equals(original.senderId));
      expect(updated.body, equals(original.body));
      expect(updated.createdAt, equals(original.createdAt));
      expect(updated.attachmentPath, equals(original.attachmentPath));
      expect(updated.attachmentPreview, same(original.attachmentPreview));
      expect(updated.localImage, same(original.localImage));
      expect(updated.replyTo, equals(original.replyTo));
      expect(updated.forwarded, equals(original.forwarded));
      expect(updated.sending, equals(original.sending));

      expect(original.photoGroup, 'g1', reason: 'the original is unchanged');
      final cleared = original.withPhotoGroup(null);
      expect(cleared.photoGroup, isNull);
    });
  });

  group('Album layout', () {
    const epsilon = 0.01;

    test('albumTiles and albumRects behavior', () {
      for (var count = 2; count <= 10; count++) {
        final tiles = albumTiles(count);
        if (count <= 4) {
          expect(tiles, equals(count));
        } else {
          expect(tiles, equals(4));
        }

        final rects = albumRects(count);
        expect(rects.length, equals(tiles));

        // Rect properties
        for (final r in rects) {
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.top, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(albumWidth + epsilon));
          expect(r.width, greaterThan(0));
          expect(r.height, greaterThan(0));
        }

        // No overlap
        for (var i = 0; i < rects.length; i++) {
          for (var j = i + 1; j < rects.length; j++) {
            final inter = rects[i].intersect(rects[j]);
            expect(inter.width <= epsilon || inter.height <= epsilon, isTrue);
          }
        }

        // Union covers full width
        final unionLeft = rects.map((r) => r.left).reduce(min);
        final unionRight = rects.map((r) => r.right).reduce(max);
        expect(unionLeft, lessThanOrEqualTo(epsilon));
        expect(unionRight, greaterThanOrEqualTo(albumWidth - epsilon));
      }

      final rects4 = albumRects(4);
      expect(albumRects(5), equals(rects4));
      expect(albumRects(10), equals(rects4));
    });
  });
}

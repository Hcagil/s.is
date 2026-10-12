import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/shared_content.dart';

void main() {
  group('SharedItem', () {
    test('stores fields correctly', () {
      const item = SharedItem(
        path: 'path/to/file',
        name: 'fileName',
        isVideo: false,
      );
      expect(item.path, equals('path/to/file'));
      expect(item.name, equals('fileName'));
      expect(item.isVideo, isFalse);
    });

    test('isVideo flag', () {
      const photo = SharedItem(
        path: 'photo.jpg',
        name: 'photo',
        isVideo: false,
      );
      const video = SharedItem(path: 'video.mp4', name: 'video', isVideo: true);
      expect(photo.isVideo, isFalse);
      expect(video.isVideo, isTrue);
    });
  });

  group('SharedContent', () {
    test('default constructor', () {
      const content = SharedContent();
      expect(content.isEmpty, isTrue);
      expect(content.photoCount, equals(0));
      expect(content.videoCount, equals(0));
    });

    test('whitespace-only text is empty', () {
      const content = SharedContent(text: '  \n\t ');
      expect(content.isEmpty, isTrue);
    });

    test('non-blank text is not empty', () {
      const content1 = SharedContent(text: 'a');
      const content2 = SharedContent(text: ' a ');
      expect(content1.isEmpty, isFalse);
      expect(content2.isEmpty, isFalse);
    });

    test('one photo with blank text is not empty', () {
      final photo = SharedItem(
        path: 'photo.jpg',
        name: 'photo',
        isVideo: false,
      );
      final content = SharedContent(text: '  \n\t ', items: [photo]);
      expect(content.isEmpty, isFalse);
    });

    test('one video only is not empty', () {
      final video = SharedItem(path: 'video.mp4', name: 'video', isVideo: true);
      final content = SharedContent(items: [video]);
      expect(content.isEmpty, isFalse);
    });

    test('mixed 3 photos + 2 videos interleaved', () {
      final items = [
        SharedItem(path: 'p1', name: 'n1', isVideo: false),
        SharedItem(path: 'p2', name: 'n2', isVideo: true),
        SharedItem(path: 'p3', name: 'n3', isVideo: false),
        SharedItem(path: 'p4', name: 'n4', isVideo: true),
        SharedItem(path: 'p5', name: 'n5', isVideo: false),
      ];
      final content = SharedContent(items: items);
      expect(content.photoCount, equals(3));
      expect(content.videoCount, equals(2));
    });

    test('only videos', () {
      final items = [
        SharedItem(path: 'v1', name: 'nv1', isVideo: true),
        SharedItem(path: 'v2', name: 'nv2', isVideo: true),
      ];
      final content = SharedContent(items: items);
      expect(content.photoCount, equals(0));
      expect(content.videoCount, equals(2));
    });

    test('constructor stores fields and items identity', () {
      final items = [
        SharedItem(path: 'p1', name: 'n1', isVideo: false),
        SharedItem(path: 'p2', name: 'n2', isVideo: true),
      ];
      final content = SharedContent(text: 'text', items: items);
      expect(content.text, equals('text'));
      expect(identical(content.items, items), isTrue);
      expect(content.isEmpty, isFalse);
    });

    test('empty text with items is not empty', () {
      final items = [SharedItem(path: 'p1', name: 'n1', isVideo: false)];
      final content = SharedContent(text: '', items: items);
      expect(content.isEmpty, isFalse);
    });

    test('whitespace text with items is not empty', () {
      final items = [SharedItem(path: 'p1', name: 'n1', isVideo: false)];
      final content = SharedContent(text: '  \n\t ', items: items);
      expect(content.isEmpty, isFalse);
    });

    test('non-blank text with no items is not empty', () {
      final content = SharedContent(text: 'hello');
      expect(content.isEmpty, isFalse);
    });

    test('non-blank text with items is not empty', () {
      final items = [SharedItem(path: 'p1', name: 'n1', isVideo: false)];
      final content = SharedContent(text: 'hello', items: items);
      expect(content.isEmpty, isFalse);
    });
  });
}

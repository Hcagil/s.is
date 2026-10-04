import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/png_size.dart';

/// Builds a minimal 24-byte PNG header with the given width and height.
/// The chunk type defaults to the ASCII bytes for "IHDR" but can be
/// overridden with [chunkType].
Uint8List buildHeader(int width, int height, {Uint8List? chunkType}) {
  final header = Uint8List(24);
  // PNG signature
  header.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final view = ByteData.sublistView(header);
  // Length of IHDR chunk data (13 bytes)
  view.setUint32(8, 13, Endian.big);

  // Chunk type (default "IHDR")
  final type = chunkType ?? Uint8List.fromList([0x49, 0x48, 0x44, 0x52]);
  header.setAll(12, type);

  // Width and height (big-endian)
  view.setUint32(16, width, Endian.big);
  view.setUint32(20, height, Endian.big);

  return header;
}

void main() {
  group('pngDimensions', () {
    test('returns correct dimensions for 24x12', () {
      final header = buildHeader(24, 12);
      expect(pngDimensions(header), equals((width: 24, height: 12)));
    });

    test('parses wide image 640x10', () {
      final header = buildHeader(640, 10);
      expect(pngDimensions(header), equals((width: 640, height: 10)));
    });

    test('parses tall image 10x480', () {
      final header = buildHeader(10, 480);
      expect(pngDimensions(header), equals((width: 10, height: 480)));
    });

    test('parses multi-byte dimensions 300x1000', () {
      final header = buildHeader(300, 1000);
      expect(pngDimensions(header), equals((width: 300, height: 1000)));
    });

    test('parses large values 0x01020304 x 0x05060708', () {
      final header = buildHeader(0x01020304, 0x05060708);
      expect(
        pngDimensions(header),
        equals((width: 0x01020304, height: 0x05060708)),
      );
    });

    test('ignores trailing bytes', () {
      final header = buildHeader(24, 12);
      final data = Uint8List.fromList([...header, 0x00, 0x01, 0xFF]);
      expect(pngDimensions(data), equals((width: 24, height: 12)));
    });

    test('returns null for null input', () {
      expect(pngDimensions(null), isNull);
    });

    test('returns null for empty list', () {
      expect(pngDimensions(Uint8List(0)), isNull);
    });

    test('returns null for fewer than 24 bytes', () {
      final header = buildHeader(24, 12);
      expect(pngDimensions(Uint8List.fromList(header.sublist(0, 23))), isNull);
    });

    test('returns null when any signature byte is corrupted', () {
      final header = buildHeader(24, 12);
      for (var i = 0; i < 4; i++) {
        final corrupted = Uint8List.fromList(header);
        corrupted[i] = 0x00; // corrupt one of the first four bytes
        expect(
          pngDimensions(corrupted),
          isNull,
          reason: 'corrupted byte $i should yield null',
        );
      }
    });

    test('returns null when width is zero', () {
      final header = buildHeader(0, 12);
      expect(pngDimensions(header), isNull);
    });

    test('returns null when height is zero', () {
      final header = buildHeader(24, 0);
      expect(pngDimensions(header), isNull);
    });

    test('parses correctly even if chunk type bytes are garbage', () {
      final header = buildHeader(
        24,
        12,
        chunkType: Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]),
      );
      expect(pngDimensions(header), equals((width: 24, height: 12)));
    });
  });
}

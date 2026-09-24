// tinyPreview, written from its contract in lib/features/chat/data/
// tiny_preview.dart: a small PNG for a receiver's blurred preview, or null
// when the source cannot be decoded at all.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/tiny_preview.dart';

import '../../support/fakes.dart' show photoPng, pngBytes;

Future<ui.Image> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a valid PNG becomes a PNG at the requested width', () async {
    // photoPng (from the shared fakes) is a real, decodable 320x240 photo.
    final preview = await tinyPreview(photoPng, width: 24);

    expect(preview, isNotNull);
    final image = await decode(preview!);
    expect(image.width, 24);
  });

  test('the aspect ratio of the source is kept', () async {
    // photoPng is 320x240 (4:3); scaled to width 24 that is height 18.
    final preview = await tinyPreview(photoPng, width: 24);

    final image = await decode(preview!);
    expect(image.width, 24);
    expect(image.height, 18);
  });

  test('the default width is 24', () async {
    final preview = await tinyPreview(photoPng);

    final image = await decode(preview!);
    expect(image.width, 24);
  });

  test(
    'a source narrower than the requested width is still decodable',
    () async {
      // pngBytes (from the shared fakes) is a real, decodable 1x1 PNG --
      // narrower than any requested preview width, so shrinking further is
      // meaningless, but decoding must still succeed rather than throw.
      final preview = await tinyPreview(pngBytes, width: 24);

      expect(preview, isNotNull);
      await decode(preview!);
    },
  );

  test('garbage bytes decode to null, not a thrown exception', () async {
    final preview = await tinyPreview(
      Uint8List.fromList(List.generate(40, (i) => i)),
    );

    expect(preview, isNull);
  });

  test('empty bytes decode to null', () async {
    final preview = await tinyPreview(Uint8List(0));

    expect(preview, isNull);
  });
}

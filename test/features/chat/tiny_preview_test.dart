// tinyPreview, written from its contract in lib/features/chat/data/
// tiny_preview.dart: a small PNG for a receiver's blurred preview, or null
// when the source cannot be decoded at all.
import 'dart:async';
import 'dart:math';
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

  group('the size cap (0.30.8): null or at most 2900 bytes', () {
    /// A PNG of random pixels: nothing for the encoder to compress.
    Future<Uint8List> noise(int w, int h) async {
      final r = Random(42);
      final px = Uint8List(w * h * 4);
      for (var i = 0; i < px.length; i++) {
        px[i] = (i % 4 == 3) ? 255 : r.nextInt(256);
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        px,
        w,
        h,
        ui.PixelFormat.rgba8888,
        done.complete,
      );
      final image = await done.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List();
    }

    for (final (w, h) in [(320, 240), (60, 3000), (3000, 60), (200, 200)]) {
      test('busy ${w}x$h', () async {
        final preview = await tinyPreview(await noise(w, h));
        if (preview != null) {
          expect(preview.length, lessThanOrEqualTo(2900));
          await decode(preview); // still a picture, not truncated bytes
        }
      });
    }

    test('a busy portrait photo still gets a (narrower) preview', () async {
      // At 24 px wide a 2:3 noise image is about 24x36x4 raw bytes, over the
      // cap; a smaller width fits, and a preview beats none.
      final preview = await tinyPreview(await noise(320, 480));
      expect(preview, isNotNull);
      expect(preview!.length, lessThanOrEqualTo(2900));
    });

    test('a busy normal photo still gets a preview', () async {
      final preview = await tinyPreview(await noise(320, 240));
      expect(preview, isNotNull, reason: 'well under the cap at 24 px');
    });
  });
}

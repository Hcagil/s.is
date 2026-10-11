// shrinkLinkImage: a downloaded page picture becomes a JPEG card picture at
// most 600 px wide (never enlarged) and at most 262144 bytes; null when it
// cannot be decoded. TARGET M3: a picture whose header claims more pixels
// than a fixed cap is refused before it is decoded.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as img;
import 'package:sis/features/chat/data/link_image_shrink.dart';

Uint8List _noisePng(int w, int h) {
  final rnd = Random(3);
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i++) {
    px[i] = (i % 4 == 3) ? 255 : rnd.nextInt(256);
  }
  return img.encodePng(
    img.Image.fromBytes(
      width: w,
      height: h,
      bytes: px.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    ),
  );
}

/// A valid 1x1 PNG whose header is rewritten to claim [w] x [h] pixels.
Uint8List _liarPng(int w, int h) {
  final png = Uint8List.fromList(_noisePng(1, 1));
  final view = ByteData.sublistView(png);
  // IHDR data starts at byte 16 (8 signature + 4 length + 4 type).
  view.setUint32(16, w);
  view.setUint32(20, h);
  view.setUint32(29, _crc(png.sublist(12, 29)));
  return png;
}

int _crc(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xffffffff;
}

void main() {
  testWidgets(
    'a wide picture becomes a JPEG at most 600 px wide and 262144 bytes',
    (tester) async {
      final out = await tester.runAsync(
        () => shrinkLinkImage(_noisePng(1200, 800)),
      );
      expect(out, isNotNull);
      expect(out!.length, lessThanOrEqualTo(262144));
      expect(out.sublist(0, 3), [0xff, 0xd8, 0xff], reason: 'JPEG signature');
      final decoded = img.decodeJpg(out);
      expect(decoded.width, 600);
      expect(decoded.height, 400, reason: 'the aspect ratio is kept');
    },
  );

  testWidgets('a small picture is never enlarged', (tester) async {
    final out = await tester.runAsync(
      () => shrinkLinkImage(_noisePng(300, 200)),
    );
    final decoded = img.decodeJpg(out!);
    expect(decoded.width, 300);
    expect(decoded.height, 200);
  });

  testWidgets('a byte budget that no quality fits gives null', (tester) async {
    final out = await tester.runAsync(
      () => shrinkLinkImage(_noisePng(600, 600), maxBytes: 200),
    );
    expect(out, isNull);
  });

  testWidgets('bytes that are no picture give null, never a throw', (
    tester,
  ) async {
    final out = await tester.runAsync(
      () => shrinkLinkImage(Uint8List.fromList(List.filled(5000, 7))),
    );
    expect(out, isNull);
  });

  testWidgets(
    'TARGET M3: a header claiming 30000 x 30000 pixels is refused before decoding',
    (tester) async {
      final watch = Stopwatch()..start();
      final out = await tester.runAsync(
        () => shrinkLinkImage(_liarPng(30000, 30000)),
      );
      expect(out, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );
}

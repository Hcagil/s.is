// shrinkToLongSide tests written from the contract.

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

void main() {
  testWidgets(
    'wide 1200x800 image shrinks to 560px long side with default limits',
    (tester) async {
      final out = await tester.runAsync(
        () => shrinkToLongSide(_noisePng(1200, 800)),
      );
      expect(out, isNotNull);
      expect(out!.length, lessThanOrEqualTo(153600));
      expect(out.sublist(0, 3), [0xff, 0xd8, 0xff], reason: 'JPEG signature');
      final decoded = img.decodeJpg(out);
      expect(decoded.width, 560);
      expect(
        decoded.height,
        inInclusiveRange(372, 374),
        reason: 'aspect ratio is kept',
      );
    },
  );

  testWidgets(
    'tall 800x1600 image shrinks to 560px long side with default limits',
    (tester) async {
      final out = await tester.runAsync(
        () => shrinkToLongSide(_noisePng(800, 1600)),
      );
      expect(out, isNotNull);
      final decoded = img.decodeJpg(out!);
      expect(decoded.height, 560);
      expect(
        decoded.width,
        inInclusiveRange(279, 281),
        reason: 'aspect ratio is kept',
      );
    },
  );

  testWidgets('square 1000x1000 image shrinks to 560x560', (tester) async {
    final out = await tester.runAsync(
      () => shrinkToLongSide(_noisePng(1000, 1000)),
    );
    expect(out, isNotNull);
    final decoded = img.decodeJpg(out!);
    expect(decoded.width, 560);
    expect(decoded.height, 560);
  });

  testWidgets('small 300x200 image is never enlarged', (tester) async {
    final out = await tester.runAsync(
      () => shrinkToLongSide(_noisePng(300, 200)),
    );
    expect(out, isNotNull);
    final decoded = img.decodeJpg(out!);
    expect(decoded.width, 300);
    expect(decoded.height, 200);
  });

  testWidgets('custom longSide 100 on 1200x800 image gives width 100', (
    tester,
  ) async {
    final out = await tester.runAsync(
      () => shrinkToLongSide(_noisePng(1200, 800), longSide: 100),
    );
    expect(out, isNotNull);
    final decoded = img.decodeJpg(out!);
    expect(decoded.width, 100);
    expect(
      decoded.height,
      inInclusiveRange(66, 68),
      reason: 'aspect ratio is kept',
    );
  });

  testWidgets('byte budget too small returns null', (tester) async {
    final out = await tester.runAsync(
      () => shrinkToLongSide(_noisePng(1200, 800), maxBytes: 10),
    );
    expect(out, isNull);
  });

  testWidgets('non-picture bytes return null', (tester) async {
    final out = await tester.runAsync(
      () => shrinkToLongSide(Uint8List.fromList([1, 2, 3, 4])),
    );
    expect(out, isNull);
  });

  testWidgets('empty Uint8List returns null', (tester) async {
    final out = await tester.runAsync(() => shrinkToLongSide(Uint8List(0)));
    expect(out, isNull);
  });
}

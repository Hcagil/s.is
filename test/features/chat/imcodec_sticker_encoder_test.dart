// This test file verifies the contract of `ImcodecStickerEncoder` as described
// in the task. It covers encoding, size limits, quality ladder behaviour,
// handling of invalid input, and compatibility with Flutter's image decoder.

import 'dart:typed_data';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/imcodec_sticker_encoder.dart';
import 'package:sis/features/chat/domain/sticker_maker.dart';
import 'package:imcodec/imcodec.dart' as img;

void main() {
  const encoder = ImcodecStickerEncoder();

  Uint8List generateFlat() {
    final data = Uint8List(512 * 512 * 4);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        final i = (y * 512 + x) * 4;
        data[i] = 200; // R
        data[i + 1] = 40; // G
        data[i + 2] = 40; // B
        data[i + 3] = 255; // A
      }
    }
    return data;
  }

  Uint8List generateHalfClear() {
    final data = Uint8List(512 * 512 * 4);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        final i = (y * 512 + x) * 4;
        if (x < 256) {
          data[i] = 200;
          data[i + 1] = 40;
          data[i + 2] = 40;
          data[i + 3] = 255;
        } else {
          data[i] = 0;
          data[i + 1] = 0;
          data[i + 2] = 0;
          data[i + 3] = 0;
        }
      }
    }
    return data;
  }

  Uint8List generateNoise() {
    final data = Uint8List(512 * 512 * 4);
    final rnd = Random(7);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        final i = (y * 512 + x) * 4;
        for (var c = 0; c < 4; c++) {
          data[i + c] = rnd.nextInt(256);
        }
      }
    }
    return data;
  }

  Uint8List generateNoiseOpaque() {
    final data = Uint8List(512 * 512 * 4);
    final rnd = Random(7);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        final i = (y * 512 + x) * 4;
        for (var c = 0; c < 3; c++) {
          data[i + c] = rnd.nextInt(256);
        }
        data[i + 3] = 255;
      }
    }
    return data;
  }

  Uint8List generateMid() {
    final data = Uint8List(512 * 512 * 4);
    final rnd = Random(7);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        final i = (y * 512 + x) * 4;
        for (var c = 0; c < 3; c++) {
          data[i + c] = ((x * 7 + y * 3) & 255) ^ rnd.nextInt(64);
        }
        data[i + 3] = 255;
      }
    }
    return data;
  }

  test('1. flat image encodes to WebP within size limit', () async {
    final flat = generateFlat();
    final result = await encoder.encode(flat);
    expect(result, isNotNull);
    final bytes = result!;
    expect(bytes.length, lessThanOrEqualTo(stickerMaxBytes));
    expect(bytes[0], 0x52); // 'R'
    expect(bytes[1], 0x49); // 'I'
    expect(bytes[2], 0x46); // 'F'
    expect(bytes[3], 0x46); // 'F'
    expect(bytes[8], 0x57); // 'W'
    expect(bytes[9], 0x45); // 'E'
    expect(bytes[10], 0x42); // 'B'
    expect(bytes[11], 0x50); // 'P'
    final decoded = img.decodeWebP(bytes);
    expect(decoded.width, 512);
    expect(decoded.height, 512);
  });

  test('2. halfClear image preserves transparency boundaries', () async {
    final halfClear = generateHalfClear();
    final result = await encoder.encode(halfClear);
    expect(result, isNotNull);
    final decoded = img.decodeWebP(result!);
    expect(decoded.alpha(400, 256), 0);
    expect(decoded.alpha(100, 256), 255);
    expect(decoded.alpha(255 - 8, 256), greaterThanOrEqualTo(250));
    expect(decoded.alpha(256 + 8, 256), lessThanOrEqualTo(5));
  });

  test('3. mid image fits only after quality ladder', () async {
    final mid = generateMid();
    final result = await encoder.encode(mid);
    expect(result, isNotNull);
    final decoded = img.decodeWebP(result!);
    expect(decoded.width, 512);
    expect(decoded.height, 512);
    expect(result.length, lessThanOrEqualTo(stickerMaxBytes));

    final midImg = img.Image.fromBytes(
      width: 512,
      height: 512,
      bytes: mid.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    final lowQualityBytes = img.encodeWebP(
      midImg,
      options: img.WebPEncodeOptions(quality: 20),
    );
    expect(result.length, greaterThan(lowQualityBytes.length));
  });

  test('4. noiseOpaque image fits only at lowest quality', () async {
    final noiseOpaque = generateNoiseOpaque();
    final result = await encoder.encode(noiseOpaque);
    expect(result, isNotNull);
    expect(result!.length, lessThanOrEqualTo(stickerMaxBytes));
  });

  test('5. noise image does not fit at any quality', () async {
    final noise = generateNoise();
    final result = await encoder.encode(noise);
    expect(result, isNull);
  });

  test('6. wrong-size input returns null without throwing', () async {
    final wrong = Uint8List(100);
    final result = await encoder.encode(wrong);
    expect(result, isNull);
  });

  testWidgets('7. result decodes with Flutter\'s image codec', (
    WidgetTester tester,
  ) async {
    final bytes = await tester.runAsync(() async {
      final result = await encoder.encode(generateHalfClear());
      expect(result, isNotNull);
      final codec = await ui.instantiateImageCodec(result!);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 512);
      expect(image.height, 512);
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      return data!.buffer.asUint8List();
    });
    final index = (256 * 512 + 400) * 4 + 3; // alpha channel
    expect(bytes![index], 0);
    expect(bytes[(256 * 512 + 100) * 4 + 3], 255);
  });
}

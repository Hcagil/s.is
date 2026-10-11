// NativeStickerCutter over the platform channel `sis/external_picker`,
// written from the contract: `cutoutSupported` -> bool, `cutoutMask`
// {bytes: 512x512 JPEG} -> 262144 alpha bytes or null. Never throws: anything
// that is not a clean answer (null, a platform error, no plugin, a mask of
// the wrong size) is false / null. The channel runs through the real
// StandardMethodCodec; only the platform side is scripted.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/native_sticker_cutter.dart';
import 'package:sis/features/chat/domain/sticker_maker.dart';

const channel = MethodChannel('sis/external_picker');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  void platform(Object? Function(MethodCall call) answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return answer(call);
        });
  }

  setUp(calls.clear);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  const cutter = NativeStickerCutter();
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
  final mask = Uint8List(stickerSide * stickerSide)
    ..[0] = 255
    ..[262143] = 128;

  group('supported', () {
    test('asks cutoutSupported and answers true', () async {
      platform((_) => true);
      expect(await cutter.supported(), isTrue);
      expect(calls.single.method, 'cutoutSupported');
    });
    test('false stays false', () async {
      platform((_) => false);
      expect(await cutter.supported(), isFalse);
    });
    test('null is false', () async {
      platform((_) => null);
      expect(await cutter.supported(), isFalse);
    });
    test('a platform error is false, not a throw', () async {
      platform((_) => throw PlatformException(code: 'boom'));
      expect(await cutter.supported(), isFalse);
    });
    test('no plugin on this platform is false, not a throw', () async {
      expect(await cutter.supported(), isFalse);
    });
  });

  group('mask', () {
    test(
      'sends cutoutMask {bytes: jpeg} and returns the 262144 bytes',
      () async {
        platform((_) => mask);
        final m = await cutter.mask(jpeg);
        expect(calls.single.method, 'cutoutMask');
        expect((calls.single.arguments as Map)['bytes'], jpeg);
        expect(m, isNotNull);
        expect(m!.length, stickerSide * stickerSide);
        expect(m, mask);
      },
    );
    test('null (no subject) is null', () async {
      platform((_) => null);
      expect(await cutter.mask(jpeg), isNull);
    });
    test('a platform error is null, not a throw', () async {
      platform((_) => throw PlatformException(code: 'model-not-ready'));
      expect(await cutter.mask(jpeg), isNull);
    });
    test('no plugin is null, not a throw', () async {
      expect(await cutter.mask(jpeg), isNull);
    });
    test('a mask of the wrong size is null', () async {
      platform((_) => Uint8List(100));
      expect(await cutter.mask(jpeg), isNull);
    });
  });
}

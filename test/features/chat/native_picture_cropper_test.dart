// NativePictureCropper at its channel boundary, written from the contract:
// MethodChannel `sis/external_picker`, method `cropPicture` with
// {path, left, top, right, bottom, size, quality}; the native side reads the
// source at `path`, writes the cropped JPEG to a file and answers its path,
// or answers a PlatformException (bad_args, crop_failed). The Dart side
// writes the source to a temporary file for it, reads the answer back, and
// deletes both files whatever happened; any failure is a null crop, never a
// throw. Real files in a real temp directory; the platform answered by a
// mock handler.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/native_picture_cropper.dart';

import '../../support/fakes.dart';

const channel = MethodChannel('sis/external_picker');
const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  late List<MethodCall> calls;

  /// What the source file held when the native side read it.
  List<int>? sourceSeen;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('picture-cropper-');
    calls = [];
    sourceSeen = null;
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getTemporaryDirectory') return tmp.path;
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    await tmp.delete(recursive: true);
  });

  /// The native side: reads the source it was pointed at, then answers.
  void platform(Future<Object?> Function(Map<Object?, Object?> args) answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map<Object?, Object?>;
      final path = args['path'];
      if (path is String && File(path).existsSync()) {
        sourceSeen = File(path).readAsBytesSync();
      }
      return answer(args);
    });
  }

  /// Everything left behind in the temporary directory.
  List<String> leftovers() => [
    for (final e in tmp.listSync(recursive: true)) e.path,
  ];

  final src = pngOf(40, 20);
  final out = pngOf(64, 64, shade: 9);
  const cropper = NativePictureCropper();

  test('passes the source by path and the rectangle, size and quality as '
      'given; answers the output\'s bytes as a JPEG; leaves no file', () async {
    platform((_) async {
      final f = File('${tmp.path}/cropped-output.jpg');
      await f.writeAsBytes(out);
      return f.path;
    });

    final result = await cropper.crop(
      src,
      left: 0.25,
      top: 0.125,
      right: 0.75,
      bottom: 1,
      size: 320,
      quality: 70,
    );

    expect(calls.single.method, 'cropPicture');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['left'], 0.25);
    expect(args['top'], 0.125);
    expect(args['right'], 0.75);
    expect(args['bottom'], 1.0);
    expect(args['size'], 320);
    expect(args['quality'], 70);
    expect(sourceSeen, src, reason: 'the native side did not get the source');

    expect(result, isNotNull);
    expect(result!.bytes, out);
    expect(result.contentType, 'image/jpeg');
    expect(result.extension, 'jpg');
    expect(leftovers(), isEmpty, reason: 'a temporary file was left behind');
  });

  test('the defaults are a 640 px square at quality 82', () async {
    platform((_) async {
      final f = File('${tmp.path}/o.jpg');
      await f.writeAsBytes(out);
      return f.path;
    });
    await cropper.crop(src, left: 0, top: 0, right: 0.5, bottom: 1);
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['size'], 640);
    expect(args['quality'], 82);
  });

  // Every code the iOS and Android handlers can raise for cropPicture.
  for (final code in ['crop_failed', 'bad_args', 'unreadable', 'not_image']) {
    test('the native side fails ($code): null, and the source file is '
        'deleted', () async {
      platform((_) async => throw PlatformException(code: code));

      final result = await cropper.crop(
        src,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      );

      expect(result, isNull);
      expect(sourceSeen, src);
      expect(leftovers(), isEmpty, reason: 'the source file was left behind');
    });
  }

  test('no answer (null): null, no file left', () async {
    platform((_) async => null);
    final result = await cropper.crop(
      src,
      left: 0,
      top: 0,
      right: 1,
      bottom: 1,
    );
    expect(result, isNull);
    expect(leftovers(), isEmpty);
  });

  test('an answer naming a file that is not there: null, not a throw, no '
      'file left', () async {
    platform((_) async => '${tmp.path}/never-written.jpg');
    final result = await cropper.crop(
      src,
      left: 0,
      top: 0,
      right: 1,
      bottom: 1,
    );
    expect(result, isNull);
    expect(leftovers(), isEmpty);
  });
}

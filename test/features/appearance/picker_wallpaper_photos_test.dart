import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/data/picker_wallpaper_photos.dart';
import 'package:sis/features/appearance/domain/wallpaper_photos.dart';
import 'package:sis/features/chat/domain/attachment.dart';

import '../../support/fakes.dart';

const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wallpaper-photos-');
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return tmp.path;
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('picked: returns WallpaperPicked and writes file', () async {
    final picker = ExternalPickerFake();
    picker.picture = PickedImage(
      bytes: Uint8List.fromList([1, 2, 3, 4, 5]),
      contentType: 'image/jpeg',
      extension: 'jpg',
    );
    final photos = PickerWallpaperPhotos(picker);

    final result = await photos.pick();

    expect(result, isA<WallpaperPicked>());
    final path = (result as WallpaperPicked).path;
    expect(path.startsWith(tmp.path), isTrue);
    final file = File(path);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), equals([1, 2, 3, 4, 5]));
    expect(picker.pictureCalls, 1);
  });

  test('two picks give two different paths and both files exist', () async {
    final picker = ExternalPickerFake();
    picker.picture = PickedImage(
      bytes: Uint8List.fromList([9, 8, 7]),
      contentType: 'image/png',
      extension: 'png',
    );
    final photos = PickerWallpaperPhotos(picker);

    final first = await photos.pick();
    final second = await photos.pick();

    expect(first, isA<WallpaperPicked>());
    expect(second, isA<WallpaperPicked>());
    final firstPath = (first as WallpaperPicked).path;
    final secondPath = (second as WallpaperPicked).path;
    expect(firstPath, isNot(equals(secondPath)));

    final firstFile = File(firstPath);
    final secondFile = File(secondPath);
    expect(firstFile.existsSync(), isTrue);
    expect(secondFile.existsSync(), isTrue);
    expect(picker.pictureCalls, 2);
  });

  test('cancelled: returns WallpaperPickCancelled and no files', () async {
    final picker = ExternalPickerFake();
    picker.picture = null;
    final photos = PickerWallpaperPhotos(picker);

    final result = await photos.pick();

    expect(result, isA<WallpaperPickCancelled>());
    expect(tmp.listSync().isEmpty, isTrue);
  });

  test('failed: returns WallpaperPickFailed and no files', () async {
    final picker = ExternalPickerFake();
    picker.failure = true;
    final photos = PickerWallpaperPhotos(picker);

    final result = await photos.pick();

    expect(result, isA<WallpaperPickFailed>());
    expect(tmp.listSync().isEmpty, isTrue);
  });

  test('directory unavailable: returns WallpaperPickFailed', () async {
    final picker = ExternalPickerFake();
    picker.picture = PickedImage(
      bytes: Uint8List.fromList([1]),
      contentType: 'image/jpeg',
      extension: 'jpg',
    );
    final photos = PickerWallpaperPhotos(picker);

    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        throw PlatformException(code: 'x');
      }
      return null;
    });

    final result = await photos.pick();

    expect(result, isA<WallpaperPickFailed>());
    expect(tmp.listSync().isEmpty, isTrue);
  });

  test('delete removes the file', () async {
    final picker = ExternalPickerFake();
    picker.picture = PickedImage(
      bytes: Uint8List.fromList([4, 5, 6]),
      contentType: 'image/gif',
      extension: 'gif',
    );
    final photos = PickerWallpaperPhotos(picker);

    final pickResult = await photos.pick();
    final path = (pickResult as WallpaperPicked).path;
    final file = File(path);
    expect(file.existsSync(), isTrue);

    await photos.delete(path);
    expect(file.existsSync(), isFalse);
  });

  test('delete non-existent path completes without throwing', () async {
    final picker = ExternalPickerFake();
    final photos = PickerWallpaperPhotos(picker);

    await expectLater(photos.delete('${tmp.path}/missing.jpg'), completes);
  });
}

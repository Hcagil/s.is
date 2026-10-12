// MethodChannelShareIntake at its boundary, written from the channel contract:
// MethodChannel `sis/share_intake`; Dart calls `take`, the platform answers
// null (nothing waits) or {text?: String, items: [{path, name, video: bool}]};
// the platform calls `arrived` on Dart when another share comes in while the
// app runs. readPhoto gives send-ready bytes (null when unreadable); discard
// deletes the cache files. Real files in a temp directory, the platform
// answered by a mock handler.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/method_channel_share_intake.dart';
import 'package:sis/features/chat/domain/shared_content.dart';

/// A real, decodable 4x4 JPEG (the shape the native side writes).
final jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQY'
  'GBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYa'
  'KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAAR'
  'CAAEAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA'
  'AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK'
  'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG'
  'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl'
  '5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA'
  'AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk'
  'NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
  'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk'
  '5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDDooorwT84P//Z',
);

const channel = MethodChannel('sis/share_intake');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;
  late List<MethodCall> calls;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('share-intake-');
    calls = [];
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  void platform(Object? Function() answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer();
    });
  }

  Future<File> file(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  group('take', () {
    test('null from the platform: nothing waits', () async {
      platform(() => null);
      expect(await MethodChannelShareIntake().take(), isNull);
      expect(calls.single.method, 'take');
    });

    test('text and items map onto SharedContent, in order', () async {
      final a = await file('a.jpg', jpeg);
      final b = await file('b.mp4', [1, 2, 3]);
      platform(
        () => {
          'text': 'look https://example.com',
          'items': [
            {'path': a.path, 'name': 'a.jpg', 'video': false},
            {'path': b.path, 'name': 'b.mp4', 'video': true},
          ],
        },
      );
      final c = (await MethodChannelShareIntake().take())!;
      expect(c.text, 'look https://example.com');
      expect(c.items.map((i) => (i.path, i.name, i.isVideo)).toList(), [
        (a.path, 'a.jpg', false),
        (b.path, 'b.mp4', true),
      ]);
    });

    test('text missing: empty text, items still read', () async {
      final a = await file('a.jpg', jpeg);
      platform(
        () => {
          'items': [
            {'path': a.path, 'name': 'a.jpg', 'video': false},
          ],
        },
      );
      final c = (await MethodChannelShareIntake().take())!;
      expect(c.text, '');
      expect(c.photoCount, 1);
    });

    test('text only (a link): no items', () async {
      platform(() => {'text': 'https://example.com/a', 'items': <Object>[]});
      final c = (await MethodChannelShareIntake().take())!;
      expect(c.text, 'https://example.com/a');
      expect(c.items, isEmpty);
    });

    test('blank text and no items: nothing to share, null', () async {
      platform(() => {'text': '  \n ', 'items': <Object>[]});
      expect(await MethodChannelShareIntake().take(), isNull);
    });

    test('a platform error or a missing plugin never throws', () async {
      for (final e in <Object>[
        PlatformException(code: 'unreadable'),
        MissingPluginException(),
      ]) {
        platform(() => throw e);
        await expectLater(
          MethodChannelShareIntake().take(),
          completion(isNull),
          reason: '$e',
        );
      }
    });
  });

  test('the platform calling `arrived` fires arrivals', () async {
    platform(() => null);
    final intake = MethodChannelShareIntake();
    final fired = Completer<void>();
    final sub = intake.arrivals.listen((_) => fired.complete());
    addTearDown(sub.cancel);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('arrived')),
      (_) {},
    );
    await fired.future.timeout(const Duration(seconds: 2));
  });

  group('readPhoto', () {
    test('a readable JPEG: its bytes, image/jpeg', () async {
      final a = await file('a.jpg', jpeg);
      final p = await MethodChannelShareIntake().readPhoto(
        SharedItem(path: a.path, name: 'a.jpg', isVideo: false),
      );
      expect(p, isNotNull);
      expect(p!.bytes, jpeg);
      expect(p.contentType, 'image/jpeg');
    });

    test('a missing file is unreadable: null, no throw', () async {
      final p = await MethodChannelShareIntake().readPhoto(
        SharedItem(
          path: '${dir.path}/gone.jpg',
          name: 'gone.jpg',
          isVideo: false,
        ),
      );
      expect(p, isNull);
    });
  });

  test('discard deletes every cache file, a missing one is fine', () async {
    final a = await file('a.jpg', jpeg);
    final b = await file('b.mp4', [1]);
    final content = SharedContent(
      text: 't',
      items: [
        SharedItem(path: a.path, name: 'a.jpg', isVideo: false),
        SharedItem(
          path: '${dir.path}/never.jpg',
          name: 'never.jpg',
          isVideo: false,
        ),
        SharedItem(path: b.path, name: 'b.mp4', isVideo: true),
      ],
    );
    await MethodChannelShareIntake().discard(content);
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
  });
}

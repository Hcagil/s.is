// ExternalPickerChannel at its boundary, written from the channel contract:
// MethodChannel `sis/external_picker`; `pickAttachments` answers
// {"paths": [...], "dropped": n}, `pickProfilePicture` answers a list of at
// most one path; null or no paths is a cancel; PlatformException not_image,
// unreadable, no_app or busy is a failure. The native side hands over files
// it copied (already JPEG); the channel reads each, deletes it, and gives an
// attachment -- never a picture -- its tiny preview. Real files in a temp
// directory, the platform answered by a mock handler.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/external_picker_channel.dart';
import 'package:sis/features/chat/domain/external_picker.dart';

/// A real, decodable 4x4 JPEG, the shape the native side writes.
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

const channel = MethodChannel('sis/external_picker');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;
  late List<MethodCall> calls;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('external-picker-');
    calls = [];
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  /// The platform answering every call with [answer] (or throwing it).
  void platform(Object? Function() answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer();
    });
  }

  /// A copied photo on disk: the 4x4 JPEG plus a tag byte after its end, so
  /// each file's bytes are its own.
  Future<File> copied(String name, int tag) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes([...jpeg, tag]);
    return f;
  }

  const picker = ExternalPickerChannel();

  group('pickAttachments', () {
    test('reads every path, in order, and passes "dropped" through', () async {
      final a = await copied('a.jpg', 1);
      final b = await copied('b.jpg', 2);
      platform(
        () => {
          'paths': [a.path, b.path],
          'dropped': 3,
        },
      );

      final result = await picker.pickAttachments();

      expect(calls.single.method, 'pickAttachments');
      expect(calls.single.arguments, isNull);
      final picked = result as ExternalPickedImages;
      expect(picked.dropped, 3);
      expect(
        [for (final i in picked.images) i.bytes],
        [
          [...jpeg, 1],
          [...jpeg, 2],
        ],
      );
      for (final i in picked.images) {
        expect(i.contentType, 'image/jpeg');
        expect(i.extension, 'jpg');
      }
    });

    test('each attachment carries a tiny preview that decodes', () async {
      final a = await copied('a.jpg', 1);
      platform(
        () => {
          'paths': [a.path],
          'dropped': 0,
        },
      );

      final picked = await picker.pickAttachments() as ExternalPickedImages;

      final preview = picked.images.single.preview;
      expect(preview, isNotNull, reason: 'a receiver sees nothing meanwhile');
      final codec = await ui.instantiateImageCodec(preview!);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, lessThanOrEqualTo(32));
    });

    test('"dropped" 0 is 0', () async {
      final a = await copied('a.jpg', 1);
      platform(
        () => {
          'paths': [a.path],
          'dropped': 0,
        },
      );

      final picked = await picker.pickAttachments() as ExternalPickedImages;
      expect(picked.dropped, 0);
    });

    test('the copies are deleted once read', () async {
      final a = await copied('a.jpg', 1);
      final b = await copied('b.jpg', 2);
      platform(
        () => {
          'paths': [a.path, b.path],
          'dropped': 0,
        },
      );

      await picker.pickAttachments();

      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isFalse);
    });

    for (final (what, answer) in [
      ('null', null),
      ('no paths', {'paths': <String>[], 'dropped': 0}),
    ]) {
      test('$what is a cancel', () async {
        platform(() => answer);
        expect(await picker.pickAttachments(), isA<ExternalPickCancelled>());
      });
    }

    for (final code in ['not_image', 'unreadable', 'no_app', 'busy']) {
      test('$code is a failure', () async {
        platform(() => throw PlatformException(code: code));
        expect(await picker.pickAttachments(), isA<ExternalPickFailed>());
      });
    }
  });

  group('pickProfilePicture', () {
    test('reads the one path, with no preview, and deletes the copy', () async {
      final a = await copied('a.jpg', 7);
      platform(() => [a.path]);

      final result = await picker.pickProfilePicture();

      expect(calls.single.method, 'pickProfilePicture');
      expect(calls.single.arguments, isNull);
      final picked = result as ExternalPickedImages;
      final image = picked.images.single;
      expect(image.bytes, [...jpeg, 7]);
      expect(image.contentType, 'image/jpeg');
      expect(image.extension, 'jpg');
      expect(
        image.preview,
        isNull,
        reason: 'a picture is not a message: it has no preview',
      );
      expect(picked.dropped, 0);
      expect(a.existsSync(), isFalse);
    });

    for (final (what, answer) in [('null', null), ('no paths', <String>[])]) {
      test('$what is a cancel', () async {
        platform(() => answer);
        expect(await picker.pickProfilePicture(), isA<ExternalPickCancelled>());
      });
    }

    for (final code in ['not_image', 'unreadable', 'no_app', 'busy']) {
      test('$code is a failure', () async {
        platform(() => throw PlatformException(code: code));
        expect(await picker.pickProfilePicture(), isA<ExternalPickFailed>());
      });
    }
  });

  // Every path the platform returned is the channel's to clean up, whatever
  // happened while reading: a failed read anywhere is a failed pick, and no
  // copy -- before or after the failure -- is left in the cache.
  group('cleanup of the copies', () {
    /// [f] unreadable to this process (the test container is not root).
    Future<void> unreadable(File f) async {
      final r = await Process.run('chmod', ['000', f.path]);
      expect(r.exitCode, 0, reason: 'chmod failed: ${r.stderr}');
      expect(
        () => f.readAsBytesSync(),
        throwsA(isA<FileSystemException>()),
        reason: 'the fixture must really be unreadable (running as root?)',
      );
    }

    test('attachments: the 2nd of 3 unreadable -> failed, and all three '
        'copies are gone, the one after it included', () async {
      final a = await copied('a.jpg', 1);
      final b = await copied('b.jpg', 2);
      final c = await copied('c.jpg', 3);
      await unreadable(b);
      platform(
        () => {
          'paths': [a.path, b.path, c.path],
          'dropped': 0,
        },
      );

      expect(await picker.pickAttachments(), isA<ExternalPickFailed>());
      expect(a.existsSync(), isFalse, reason: 'read before the failure');
      expect(b.existsSync(), isFalse, reason: 'the one that failed');
      expect(c.existsSync(), isFalse, reason: 'never read, still returned');
    });

    test('attachments: a copy already missing -> failed without throwing, '
        'the others deleted', () async {
      final a = await copied('a.jpg', 1);
      final gone = File('${dir.path}/gone.jpg');
      final c = await copied('c.jpg', 3);
      platform(
        () => {
          'paths': [a.path, gone.path, c.path],
          'dropped': 0,
        },
      );

      expect(await picker.pickAttachments(), isA<ExternalPickFailed>());
      expect(a.existsSync(), isFalse);
      expect(c.existsSync(), isFalse);
    });

    test('attachments: the very first copy missing -> failed, every other '
        'copy deleted', () async {
      final gone = File('${dir.path}/gone.jpg');
      final b = await copied('b.jpg', 2);
      final c = await copied('c.jpg', 3);
      platform(
        () => {
          'paths': [gone.path, b.path, c.path],
          'dropped': 0,
        },
      );

      expect(await picker.pickAttachments(), isA<ExternalPickFailed>());
      expect(b.existsSync(), isFalse);
      expect(c.existsSync(), isFalse);
    });

    test('attachments: bytes no decoder can read -- the preview step gets '
        'nothing to work with -- still leave no copy behind', () async {
      final a = File('${dir.path}/a.jpg');
      await a.writeAsBytes(utf8.encode('this is not a photo at all'));
      final b = await copied('b.jpg', 2);
      platform(
        () => {
          'paths': [a.path, b.path],
          'dropped': 0,
        },
      );

      await picker.pickAttachments();
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isFalse);
    });

    test('picture: an unreadable copy -> failed, and it is deleted', () async {
      final a = await copied('a.jpg', 7);
      await unreadable(a);
      platform(() => [a.path]);

      expect(await picker.pickProfilePicture(), isA<ExternalPickFailed>());
      expect(a.existsSync(), isFalse);
    });

    test('picture: a copy already missing -> failed, no throw', () async {
      platform(() => ['${dir.path}/gone.jpg']);
      expect(await picker.pickProfilePicture(), isA<ExternalPickFailed>());
    });
  });
}

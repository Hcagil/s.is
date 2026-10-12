// SharedPrefsSendQueueStore.clear() on a replaced phone: it deletes every
// member's queue AND the queued files, but only files inside the app's own
// temp, support or documents folders. A file the member picked from the
// gallery is the original and is never touched. When path_provider has no
// platform side, clear() still removes the queue keys.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/shared_prefs_send_queue_store.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/chat/domain/video.dart';

const _channel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root, temp, support, docs, gallery, lookalike;
  const store = SharedPrefsSendQueueStore();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'sis.other.setting': 'kept'});
    root = Directory.systemTemp.createTempSync('sendq-clear');
    temp = Directory('${root.path}/tmp')..createSync();
    support = Directory('${root.path}/support')..createSync();
    docs = Directory('${root.path}/docs')..createSync();
    gallery = Directory('${root.path}/DCIM')..createSync();
    // Shares the temp folder's name as a prefix but is not inside it.
    lookalike = Directory('${root.path}/tmp-gallery')..createSync();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    root.deleteSync(recursive: true);
  });

  void folders() => messenger.setMockMethodCallHandler(_channel, (call) async {
    return switch (call.method) {
      'getTemporaryDirectory' => temp.path,
      'getApplicationSupportDirectory' => support.path,
      'getApplicationDocumentsDirectory' => docs.path,
      _ => null,
    };
  });

  File file(Directory d, String name) =>
      File('${d.path}/$name')..writeAsStringSync('x');

  QueuedRecord withFile(String id, File f) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime(2026, 10, 12),
    body: '',
    file: PickedFile(
      id: 'pf$id',
      path: f.path,
      name: 'f.bin',
      mime: 'application/octet-stream',
      size: 1,
    ),
  );

  QueuedRecord withVideo(String id, File f) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime(2026, 10, 12),
    body: '',
    video: VideoSource(
      id: 'pv$id',
      path: f.path,
      name: 'v.mp4',
      size: 1,
      durationMs: 1000,
      width: 10,
      height: 10,
      thumbPath: '${root.path}/thumb-$id.jpg',
    ),
  );

  Future<List<String>> queueKeys() async =>
      (await SharedPreferences.getInstance())
          .getKeys()
          .where((k) => k.startsWith('sis.sendqueue.'))
          .toList();

  test('clear deletes queued files in the app\'s temp, support and documents '
      'folders, for every member', () async {
    folders();
    final a = file(temp, 'a.jpg');
    final b = file(support, 'b.bin');
    final c = file(docs, 'c.mp4');
    await store.save('u1', [withFile('1', a), withFile('2', b)]);
    await store.save('u2', [withVideo('3', c)]);
    expect(await queueKeys(), hasLength(2), reason: 'setup');

    await store.clear();

    expect(a.existsSync(), isFalse, reason: 'temp file kept');
    expect(b.existsSync(), isFalse, reason: 'support file kept');
    expect(c.existsSync(), isFalse, reason: 'documents video kept');
    expect(await queueKeys(), isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString('sis.other.setting'),
      'kept',
    );
  });

  test('clear never deletes a gallery original, nor a file in a folder that '
      'only shares the app folder\'s name prefix', () async {
    folders();
    final original = file(gallery, 'IMG_0001.jpg');
    final video = file(gallery, 'VID_0001.mp4');
    final near = file(lookalike, 'IMG_0002.jpg');
    final own = file(temp, 'copy.jpg');
    await store.save('u1', [
      withFile('1', original),
      withVideo('2', video),
      withFile('3', near),
      withFile('4', own),
    ]);

    await store.clear();

    expect(original.existsSync(), isTrue, reason: 'gallery photo deleted');
    expect(video.existsSync(), isTrue, reason: 'gallery video deleted');
    expect(near.existsSync(), isTrue, reason: 'prefix look-alike deleted');
    expect(own.existsSync(), isFalse, reason: 'control: own copy kept');
    expect(await queueKeys(), isEmpty);
  });

  test(
    'a file reached through ".." out of the app folder is not deleted',
    () async {
      folders();
      final original = file(gallery, 'IMG_0003.jpg');
      final sneaky = File('${temp.path}/../DCIM/IMG_0003.jpg');
      await store.save('u1', [withFile('1', sneaky)]);

      await store.clear();

      expect(original.existsSync(), isTrue);
      expect(await queueKeys(), isEmpty);
    },
  );

  test('without path_provider, clear still removes every queue key and '
      'deletes nothing', () async {
    // No handler: every path_provider call fails (MissingPluginException).
    final original = file(gallery, 'IMG_0004.jpg');
    final own = file(temp, 'copy.jpg');
    await store.save('u1', [withFile('1', original)]);
    await store.save('u2', [withFile('2', own)]);
    expect(await queueKeys(), hasLength(2), reason: 'setup');

    await store.clear();

    expect(await queueKeys(), isEmpty);
    expect(original.existsSync(), isTrue);
    expect(
      (await SharedPreferences.getInstance()).getString('sis.other.setting'),
      'kept',
    );
  });

  test(
    'path_provider failing with an error: clear still removes the keys',
    () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => throw PlatformException(code: 'boom'),
      );
      await store.save('u1', [withFile('1', file(temp, 'a.jpg'))]);

      await store.clear();

      expect(await queueKeys(), isEmpty);
    },
  );
}

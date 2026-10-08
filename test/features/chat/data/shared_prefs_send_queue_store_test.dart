import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/shared_prefs_send_queue_store.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/video.dart';

void main() {
  late Directory tempDir;
  late SharedPrefsSendQueueStore store;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('sendq');
    store = SharedPrefsSendQueueStore();
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  QueuedRecord textRecord(String id) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime.now(),
    body: 'text',
  );

  QueuedRecord fileRecord(String id, String filePath) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime.now(),
    body: 'file',
    file: PickedFile(
      id: 'pf$id',
      path: filePath,
      name: 'file.txt',
      mime: 'text/plain',
      size: 1,
    ),
  );

  QueuedRecord videoRecord(String id, String videoPath) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime.now(),
    body: 'video',
    video: VideoSource(
      id: 'pv$id',
      path: videoPath,
      name: 'video.mp4',
      size: 1,
      durationMs: 1000,
      width: 100,
      height: 100,
      thumbPath: '$videoPath-thumb',
    ),
  );

  Future<File> createFile(String name) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString('x');
    return file;
  }

  test('save then load returns same records', () async {
    final file = await createFile('file.txt');
    final video = await createFile('video.mp4');

    final records = [
      textRecord('t1'),
      fileRecord('f1', file.path),
      videoRecord('v1', video.path),
    ];

    await store.save('u1', records);
    final loaded = await store.load('u1');

    expect(loaded.length, 3);
    expect(loaded[0].id, 't1');
    expect(loaded[1].id, 'f1');
    expect(loaded[1].file?.path, file.path);
    expect(loaded[2].id, 'v1');
    expect(loaded[2].video?.path, video.path);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sis.sendqueue.u1'), isNotNull);
  });

  test('load for a user never saved returns empty list', () async {
    final loaded = await store.load('u2');
    expect(loaded, isEmpty);
  });

  test('users are separate', () async {
    final file1 = await createFile('file1.txt');
    final file2 = await createFile('file2.txt');

    await store.save('u1', [fileRecord('f1', file1.path)]);
    await store.save('u2', [fileRecord('f2', file2.path)]);

    final loadedU1 = await store.load('u1');
    final loadedU2 = await store.load('u2');

    expect(loadedU1.length, 1);
    expect(loadedU1[0].id, 'f1');
    expect(loadedU2.length, 1);
    expect(loadedU2[0].id, 'f2');
  });

  test('save with empty list removes the key', () async {
    final file = await createFile('file.txt');
    await store.save('u1', [fileRecord('f1', file.path)]);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.startsWith('sis.sendqueue.')), isTrue);

    await store.save('u1', []);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.startsWith('sis.sendqueue.')), isFalse);
  });

  test('file record missing on disk is dropped', () async {
    final file = await createFile('file.txt');
    final text = textRecord('t1');

    await store.save('u1', [fileRecord('f1', file.path), text]);

    // Delete the file before loading
    file.deleteSync();

    final loaded = await store.load('u1');
    expect(loaded.length, 1);
    expect(loaded[0].id, 't1');
  });

  test('video record missing on disk is dropped', () async {
    final video = await createFile('video.mp4');
    final text = textRecord('t1');

    await store.save('u1', [videoRecord('v1', video.path), text]);

    // Delete the video file before loading
    video.deleteSync();

    final loaded = await store.load('u1');
    expect(loaded.length, 1);
    expect(loaded[0].id, 't1');
  });

  test('clear removes only sendqueue keys', () async {
    SharedPreferences.setMockInitialValues({'sis.appearance': 'keep'});
    final file = await createFile('file.txt');

    await store.save('u1', [fileRecord('f1', file.path)]);
    await store.save('u2', [fileRecord('f2', file.path)]);

    await store.clear();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.startsWith('sis.sendqueue.')), isFalse);
    expect(prefs.getString('sis.appearance'), 'keep');
  });

  test('garbage stored under key results in empty load', () async {
    SharedPreferences.setMockInitialValues({'sis.sendqueue.u1': 'not json'});
    final loaded = await store.load('u1');
    expect(loaded, isEmpty);
  });

  test('save replaces existing records', () async {
    final file = await createFile('file.txt');
    final a = fileRecord('a', file.path);
    final b = fileRecord('b', file.path);

    await store.save('u1', [a, b]);
    await store.save('u1', [b]);

    final loaded = await store.load('u1');
    expect(loaded.length, 1);
    expect(loaded[0].id, 'b');
  });
}

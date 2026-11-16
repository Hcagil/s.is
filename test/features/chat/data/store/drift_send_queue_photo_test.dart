// DriftSendQueueStore photo tests – over a REAL encrypted store file.
// Uses the same harness and helpers as drift_send_queue_store_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_send_queue_store.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';

import 'store_harness.dart';

const _channel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late StoreHarness h;
  late String key;
  late DriftMessageStore db;
  late DriftSendQueueStore store;
  late Directory root, temp, support, docs, gallery;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'sis.other.setting': 'kept'});
    h = await StoreHarness.create();
    key = await h.newKey();
    db = h.open(owner: 'u1', key: key);
    addTearDown(() => db.close());
    store = DriftSendQueueStore(db);
    root = Directory('${h.dir.path}/phone')..createSync();
    temp = Directory('${root.path}/tmp')..createSync();
    support = Directory('${root.path}/support')..createSync();
    docs = Directory('${root.path}/docs')..createSync();
    gallery = Directory('${root.path}/DCIM')..createSync();
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

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

  QueuedRecord text(String id, {String body = 'text', int at = 0}) =>
      QueuedRecord(
        id: id,
        conversationId: 'c1',
        createdAt: DateTime(2026, 10, 12, 9, 0, at),
        body: body,
      );

  List<String> ids(List<QueuedRecord> rs) => [for (final r in rs) r.id];

  // Helper for photo records.
  QueuedRecord withPhoto(String id, File f) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime(2026, 10, 12),
    photo: QueuedPhoto(
      file: PickedFile(
        id: id,
        path: f.path,
        name: 'p.png',
        mime: 'image/png',
        size: 1,
      ),
    ),
  );

  group('photos in the send queue', () {
    test('a photo record is saved and read back with its kept file', () async {
      final f = file(support, 'p1.png');
      await store.save('u1', [withPhoto('p1', f)]);
      final back = await store.load('u1');
      expect(ids(back), ['p1']);
      final rec = back.first;
      expect(rec.photo, isNotNull);
      expect(rec.photo!.file.path, f.path);
    });

    test(
      'a photo whose kept file is gone from the phone is left out',
      () async {
        final f1 = file(support, 'p1.png');
        final f2 = file(support, 'p2.png');
        await store.save('u1', [
          withPhoto('p1', f1),
          withPhoto('p2', f2),
          text('t'),
        ]);
        f2.deleteSync();
        final back = await store.load('u1');
        expect(ids(back), ['p1', 't']);
      },
    );

    test('clear deletes a queued photo inside the app folders but never a gallery original', () async {
      folders();
      final inFile = file(support, 'in.png');
      final origFile = file(gallery, 'orig.png');
      await store.save('u1', [
        withPhoto('in', inFile),
        withPhoto('orig', origFile),
      ]);
      await store.clear();
      expect(inFile.existsSync(), isFalse, reason: 'support photo deleted');
      expect(origFile.existsSync(), isTrue, reason: 'gallery photo kept');
      expect(await store.load('u1'), isEmpty);
    });
  });
}

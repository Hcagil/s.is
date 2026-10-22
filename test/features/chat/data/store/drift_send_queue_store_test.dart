// DriftSendQueueStore over a REAL encrypted store file, and
// moveLegacySendQueue from the old preferences queue into it. Written from
// the SendQueueStore / QueuedCiphertexts contract and the send-path contract
// (queue rows keep their ciphertext; clear() deletes queued files only inside
// the app's own folders), never from the implementation.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_send_queue_store.dart';
import 'package:sis/features/chat/data/store/legacy_send_queue.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/chat/domain/video.dart';

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
  late Directory root, temp, support, docs, gallery, lookalike;

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
    // Shares the temp folder's name as a prefix but is not inside it.
    lookalike = Directory('${root.path}/tmp-gallery')..createSync();
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

  QueuedRecord withFile(String id, File f) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime(2026, 10, 12),
    file: PickedFile(
      id: id,
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
    video: VideoSource(
      id: id,
      path: f.path,
      name: 'v.mp4',
      size: 1,
      durationMs: 1000,
      width: 10,
      height: 10,
      thumbPath: '${root.path}/thumb-$id.jpg',
    ),
  );

  List<String> ids(List<QueuedRecord> rs) => [for (final r in rs) r.id];

  group('save and load', () {
    test('save then load gives the same records, in the order saved', () async {
      final f = file(temp, 'a.pdf');
      await store.save('u1', [text('t1', at: 1), withFile('f1', f)]);
      final back = await store.load('u1');
      expect(ids(back), ['t1', 'f1']);
      expect(back[0].body, 'text');
      expect(back[1].file!.path, f.path);
    });

    test('a member never saved has nothing; members are separate', () async {
      expect(await store.load('u1'), isEmpty);
      await store.save('u1', [text('a')]);
      await store.save('u2', [text('b')]);
      expect(ids(await store.load('u1')), ['a']);
      expect(ids(await store.load('u2')), ['b']);
    });

    test(
      'save replaces what was saved; an empty save leaves nothing',
      () async {
        await store.save('u1', [text('a'), text('b', at: 1)]);
        await store.save('u1', [text('b', at: 1)]);
        expect(ids(await store.load('u1')), ['b']);
        await store.save('u1', const []);
        expect(await store.load('u1'), isEmpty);
      },
    );

    test('a file or video gone from the phone is left out', () async {
      final f = file(temp, 'a.pdf');
      final v = file(temp, 'v.mov');
      await store.save('u1', [
        withFile('f1', f),
        withVideo('v1', v),
        text('t'),
      ]);
      f.deleteSync();
      v.deleteSync();
      expect(ids(await store.load('u1')), ['t']);
    });

    test('the queue survives closing and reopening the store file', () async {
      await store.save('u1', [text('t1', body: 'still here')]);
      await db.close();
      final again = h.open(owner: 'u1', key: key);
      addTearDown(again.close);
      final back = await DriftSendQueueStore(again).load('u1');
      expect(ids(back), ['t1']);
      expect(back.single.body, 'still here');
    });
  });

  group('ciphertext on the queue row', () {
    test('a saved ciphertext is read back; none -> null', () async {
      await store.save('u1', [text('t1'), text('t2', at: 1)]);
      expect(await store.ciphertextOf('u1', 't1'), isNull);
      expect(await store.setCiphertext('u1', 't1', 'Q0lQSEVS', 0), isTrue);
      final c = await store.ciphertextOf('u1', 't1');
      expect((c!.ciphertext, c.olmType), ('Q0lQSEVS', 0));
      expect(await store.ciphertextOf('u1', 't2'), isNull);
      expect(await store.ciphertextOf('u2', 't1'), isNull);
    });

    test(
      'save keeps the ciphertext of a row that stays in the queue',
      () async {
        await store.save('u1', [text('t1')]);
        await store.setCiphertext('u1', 't1', 'Q0lQSEVS', 1);
        // The queue is saved again (another send added, the first unchanged).
        await store.save('u1', [text('t1'), text('t2', at: 1)]);
        final c = await store.ciphertextOf('u1', 't1');
        expect((c?.ciphertext, c?.olmType), ('Q0lQSEVS', 1));
      },
    );

    test(
      'the row (and its ciphertext) goes when the item leaves the queue',
      () async {
        await store.save('u1', [text('t1')]);
        await store.setCiphertext('u1', 't1', 'Q0lQSEVS', 0);
        await store.save('u1', const []);
        expect(await store.ciphertextOf('u1', 't1'), isNull);
        // The same id queued again is a new row: no stale ciphertext.
        await store.save('u1', [text('t1')]);
        expect(await store.ciphertextOf('u1', 't1'), isNull);
      },
    );

    test('setCiphertext on a row that does not exist writes nothing', () async {
      expect(await store.setCiphertext('u1', 'nope', 'Q0lQSEVS', 0), isFalse);
      expect(await store.ciphertextOf('u1', 'nope'), isNull);
      await store.save('u1', [text('a')]);
      expect(
        await store.setCiphertext('u2', 'a', 'Q0lQSEVS', 0),
        isFalse,
        reason: "another member's row was written",
      );
      expect(await store.ciphertextOf('u2', 'a'), isNull);
    });

    test('clear drops every ciphertext', () async {
      await store.save('u1', [text('t1')]);
      await store.setCiphertext('u1', 't1', 'Q0lQSEVS', 0);
      await store.clear();
      expect(await store.ciphertextOf('u1', 't1'), isNull);
      await store.save('u1', [text('t1')]);
      expect(await store.ciphertextOf('u1', 't1'), isNull);
    });
  });

  group('clear', () {
    test("deletes queued files in the app's temp, support and documents "
        'folders, for every member, and every row', () async {
      folders();
      final a = file(temp, 'a.jpg');
      final b = file(support, 'b.bin');
      final c = file(docs, 'c.mp4');
      await store.save('u1', [withFile('1', a), withFile('2', b)]);
      await store.save('u2', [withVideo('3', c)]);

      await store.clear();

      expect(a.existsSync(), isFalse, reason: 'temp file kept');
      expect(b.existsSync(), isFalse, reason: 'support file kept');
      expect(c.existsSync(), isFalse, reason: 'documents video kept');
      expect(await store.load('u1'), isEmpty);
      expect(await store.load('u2'), isEmpty);
    });

    test('never deletes a gallery original, nor a file in a folder that only '
        "shares the app folder's name prefix", () async {
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
      expect(await store.load('u1'), isEmpty);
    });

    test(
      'a file reached through ".." out of the app folder is not deleted',
      () async {
        folders();
        final original = file(gallery, 'IMG_0003.jpg');
        final sneaky = File('${temp.path}/../DCIM/IMG_0003.jpg');
        final own = file(temp, 'copy.jpg');
        await store.save('u1', [withFile('1', sneaky), withFile('2', own)]);

        await store.clear();

        expect(original.existsSync(), isTrue);
        expect(own.existsSync(), isFalse, reason: 'control: own copy kept');
        expect(await store.load('u1'), isEmpty);
      },
    );

    test('without path_provider, clear still removes every row and deletes '
        'nothing', () async {
      // No handler: every path_provider call fails (MissingPluginException).
      final original = file(gallery, 'IMG_0004.jpg');
      final own = file(temp, 'copy.jpg');
      await store.save('u1', [withFile('1', original)]);
      await store.save('u2', [withFile('2', own)]);

      await store.clear();

      expect(await store.load('u1'), isEmpty);
      expect(await store.load('u2'), isEmpty);
      expect(original.existsSync(), isTrue);
      expect(own.existsSync(), isTrue);
    });

    test(
      'path_provider failing with an error: clear still removes the rows',
      () async {
        messenger.setMockMethodCallHandler(
          _channel,
          (call) async => throw PlatformException(code: 'boom'),
        );
        await store.save('u1', [withFile('1', file(temp, 'a.jpg'))]);

        await store.clear();

        expect(await store.load('u1'), isEmpty);
      },
    );
  });

  group('moveLegacySendQueue', () {
    test("appends the member's old prefs queue, skips ids already held, and "
        'removes every sis.sendqueue. key', () async {
      SharedPreferences.setMockInitialValues({
        'sis.sendqueue.u1': encodeQueue([
          text('old1', body: 'from prefs', at: 5),
          text('held', body: 'prefs copy', at: 6),
        ]),
        'sis.sendqueue.u2': encodeQueue([text('other', body: 'u2 text')]),
        'sis.other.setting': 'kept',
      });
      await store.save('u1', [text('held', body: 'store copy')]);

      await moveLegacySendQueue(store, 'u1');

      final back = await store.load('u1');
      expect(ids(back).toSet(), {'held', 'old1'});
      expect(back.length, 2, reason: 'a held id was added twice');
      expect(
        back.firstWhere((r) => r.id == 'held').body,
        'store copy',
        reason: 'the stored record was overwritten by the prefs one',
      );
      expect(back.firstWhere((r) => r.id == 'old1').body, 'from prefs');
      expect(await store.load('u2'), isEmpty, reason: 'not the owner');
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getKeys().where((k) => k.startsWith('sis.sendqueue.')),
        isEmpty,
      );
      expect(prefs.getString('sis.other.setting'), 'kept');
    });

    test('a moved text keeps the ciphertext of a held row untouched', () async {
      SharedPreferences.setMockInitialValues({
        'sis.sendqueue.u1': encodeQueue([text('old1', at: 5)]),
      });
      await store.save('u1', [text('held')]);
      await store.setCiphertext('u1', 'held', 'Q0lQSEVS', 1);

      await moveLegacySendQueue(store, 'u1');

      expect((await store.ciphertextOf('u1', 'held'))?.ciphertext, 'Q0lQSEVS');
    });

    test('nothing in prefs: the store is left as it is', () async {
      await store.save('u1', [text('held')]);
      await moveLegacySendQueue(store, 'u1');
      expect(ids(await store.load('u1')), ['held']);
    });
  });
}

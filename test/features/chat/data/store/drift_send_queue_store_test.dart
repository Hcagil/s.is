import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/data/store/drift_send_queue_store.dart';

import 'store_harness.dart';

void main() {
  // Helpers
  QueuedRecord textRecord(String id, {String? replyTo}) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime.now(),
    body: 'text',
    replyTo: replyTo,
  );

  QueuedRecord fileRecord(String id, String filePath, {String? replyTo}) =>
      QueuedRecord(
        id: id,
        conversationId: 'c1',
        createdAt: DateTime.now(),
        body: 'file',
        replyTo: replyTo,
        file: PickedFile(
          id: 'pf$id',
          path: filePath,
          name: 'file.txt',
          mime: 'text/plain',
          size: 1,
        ),
      );

  QueuedRecord videoRecord(String id, String videoPath, {String? replyTo}) =>
      QueuedRecord(
        id: id,
        conversationId: 'c1',
        createdAt: DateTime.now(),
        body: 'video',
        replyTo: replyTo,
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

  QueuedRecord stickerRecord(String id, {String? replyTo}) => QueuedRecord(
    id: id,
    conversationId: 'c1',
    createdAt: DateTime.now(),
    body: 'sticker',
    replyTo: replyTo,
    stickerId: 'sticker-$id',
  );

  Future<File> createFile(String name, Directory dir) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString('x');
    return file;
  }

  Future<DriftSendQueueStore> openStore(
    StoreHarness h,
    String owner,
    String key,
  ) async {
    final messageStore = h.open(owner: owner, key: key);
    final store = DriftSendQueueStore(messageStore);
    addTearDown(() async => await messageStore.close());
    return store;
  }

  test('save then load returns the same records in order', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    final file = await createFile('file.txt', h.dir);
    final video = await createFile('video.mp4', h.dir);

    final records = [
      textRecord('t1'),
      fileRecord('f1', file.path),
      videoRecord('v1', video.path),
      stickerRecord('s1'),
    ];

    await store.save('u1', records);
    final loaded = await store.load('u1');

    expect(loaded.length, 4, reason: 'four records loaded');
    expect(loaded[0].id, 't1', reason: 'id matches');
    expect(loaded[0].conversationId, 'c1', reason: 'conversationId matches');
    expect(loaded[0].body, 'text', reason: 'body matches');

    expect(loaded[1].id, 'f1', reason: 'file id matches');
    expect(loaded[1].file?.path, file.path, reason: 'file path matches');

    expect(loaded[2].id, 'v1', reason: 'video id matches');
    expect(loaded[2].video?.path, video.path, reason: 'video path matches');

    expect(loaded[3].id, 's1', reason: 'sticker id matches');
    expect(loaded[3].stickerId, 'sticker-s1', reason: 'stickerId matches');
  });

  test('load for a user never saved returns empty', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    final loaded = await store.load('u2');
    expect(loaded.isEmpty, true, reason: 'empty list for unsaved user');
  });

  test('users are separate', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('t1')]);
    await store.save('u2', [textRecord('t2')]);

    final l1 = await store.load('u1');
    final l2 = await store.load('u2');

    expect(l1.length, 1, reason: 'u1 has one record');
    expect(l1[0].id, 't1', reason: 'u1 record id');
    expect(l2.length, 1, reason: 'u2 has one record');
    expect(l2[0].id, 't2', reason: 'u2 record id');
  });

  test('save replaces existing records', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a'), textRecord('b'), textRecord('c')]);
    await store.save('u1', [textRecord('c'), textRecord('a')]);

    final loaded = await store.load('u1');
    expect(loaded.map((r) => r.id).toList(), [
      'c',
      'a',
    ], reason: 'order preserved after replace');
  });

  test('save empty list results in empty load', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', []);
    final loaded = await store.load('u1');
    expect(loaded.isEmpty, true, reason: 'empty after saving empty list');
  });

  test('file record missing on disk is dropped', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    final file = await createFile('file.txt', h.dir);
    await store.save('u1', [fileRecord('f1', file.path), textRecord('t1')]);

    file.deleteSync();
    final loaded = await store.load('u1');
    expect(loaded.length, 1, reason: 'only text record remains');
    expect(loaded[0].id, 't1', reason: 'text record id');
  });

  test('video record missing on disk is dropped', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    final video = await createFile('video.mp4', h.dir);
    await store.save('u1', [videoRecord('v1', video.path), textRecord('t1')]);

    video.deleteSync();
    final loaded = await store.load('u1');
    expect(loaded.length, 1, reason: 'only text record remains');
    expect(loaded[0].id, 't1', reason: 'text record id');
  });

  test('clear removes all records for all users', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('t1')]);
    await store.save('u2', [textRecord('t2')]);

    await store.clear();

    final l1 = await store.load('u1');
    final l2 = await store.load('u2');
    expect(l1.isEmpty, true, reason: 'u1 empty after clear');
    expect(l2.isEmpty, true, reason: 'u2 empty after clear');
  });

  test('store survives close and reopen', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();

    // Open, save, close
    var messageStore = h.open(owner: 'owner-1', key: key);
    var store = DriftSendQueueStore(messageStore);
    addTearDown(() async => await messageStore.close());

    await store.save('u1', [textRecord('t1')]);

    await messageStore.close();

    // Reopen
    messageStore = h.open(owner: 'owner-1', key: key);
    store = DriftSendQueueStore(messageStore);
    addTearDown(() async => await messageStore.close());

    final loaded = await store.load('u1');
    expect(loaded.length, 1, reason: 'record persisted after reopen');
    expect(loaded[0].id, 't1', reason: 'id matches after reopen');
  });

  test('setCiphertext returns true and ciphertextOf returns same', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a')]);

    final ok0 = await store.setCiphertext('u1', 'a', 'cipher0', 0);
    expect(ok0, true, reason: 'setCiphertext returned true for olmType 0');

    final ct0 = await store.ciphertextOf('u1', 'a');
    expect(ct0, isNotNull, reason: 'ciphertext present');
    expect(ct0!.ciphertext, 'cipher0', reason: 'ciphertext matches');
    expect(ct0.olmType, 0, reason: 'olmType matches');

    final ok1 = await store.setCiphertext('u1', 'a', 'cipher1', 1);
    expect(ok1, true, reason: 'setCiphertext returned true for olmType 1');

    final ct1 = await store.ciphertextOf('u1', 'a');
    expect(ct1, isNotNull, reason: 'ciphertext present after update');
    expect(ct1!.ciphertext, 'cipher1', reason: 'ciphertext updated');
    expect(ct1.olmType, 1, reason: 'olmType updated');
  });

  test(
    'setCiphertext for unknown id returns false and other user null',
    () async {
      final h = await StoreHarness.create();
      final key = await h.newKey();
      final store = await openStore(h, 'owner-1', key);

      await store.save('u1', [textRecord('a')]);

      final ok = await store.setCiphertext('u1', 'b', 'cipher', 0);
      expect(ok, false, reason: 'unknown id returns false');

      final ct = await store.ciphertextOf('u1', 'b');
      expect(ct, isNull, reason: 'ciphertext null for unknown id');

      expect(
        await store.setCiphertext('u2', 'a', 'cipher', 0),
        false,
        reason: 'another member\'s row updated',
      );
      final ctOther = await store.ciphertextOf('u2', 'a');
      expect(ctOther, isNull, reason: 'other user has no ciphertext');
    },
  );

  test('ciphertextOf before any setCiphertext returns null', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a')]);

    final ct = await store.ciphertextOf('u1', 'a');
    expect(ct, isNull, reason: 'no ciphertext before set');
  });

  test('ciphertext is kept across save()', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a'), textRecord('b')]);
    await store.setCiphertext('u1', 'a', 'cipher', 0);

    // Reorder and save again
    await store.save('u1', [textRecord('b'), textRecord('a')]);

    final ctA = await store.ciphertextOf('u1', 'a');
    expect(ctA, isNotNull, reason: 'ciphertext persists');
    expect(ctA!.ciphertext, 'cipher', reason: 'ciphertext value');
    expect(ctA.olmType, 0, reason: 'olmType value');

    final ctB = await store.ciphertextOf('u1', 'b');
    expect(ctB, isNull, reason: 'b has no ciphertext');
  });

  test('removed record loses its ciphertext', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a'), textRecord('b')]);
    await store.setCiphertext('u1', 'a', 'cipher', 0);

    // Remove a
    await store.save('u1', [textRecord('b')]);

    final ctA = await store.ciphertextOf('u1', 'a');
    expect(ctA, isNull, reason: 'ciphertext removed with record');
  });

  test('clear drops ciphertext', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a')]);
    await store.setCiphertext('u1', 'a', 'cipher', 0);

    await store.clear();

    final ct = await store.ciphertextOf('u1', 'a');
    expect(ct, isNull, reason: 'ciphertext cleared');
  });

  test('ciphertext is user specific', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final store = await openStore(h, 'owner-1', key);

    await store.save('u1', [textRecord('a')]);
    await store.save('u2', [textRecord('a')]);

    await store.setCiphertext('u1', 'a', 'cipher-u1', 0);
    await store.setCiphertext('u2', 'a', 'cipher-u2', 1);

    final ctU1 = await store.ciphertextOf('u1', 'a');
    final ctU2 = await store.ciphertextOf('u2', 'a');

    expect(ctU1, isNotNull, reason: 'u1 ciphertext present');
    expect(ctU1!.ciphertext, 'cipher-u1', reason: 'u1 ciphertext value');
    expect(ctU1.olmType, 0, reason: 'u1 olmType');

    expect(ctU2, isNotNull, reason: 'u2 ciphertext present');
    expect(ctU2!.ciphertext, 'cipher-u2', reason: 'u2 ciphertext value');
    expect(ctU2.olmType, 1, reason: 'u2 olmType');
  });
}

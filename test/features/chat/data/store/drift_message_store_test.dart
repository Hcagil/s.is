// DriftMessageStore against a REAL SQLite3 Multiple Ciphers database file,
// written from the MessageStore contract
// (lib/features/chat/domain/message_store.dart), never from the
// implementation. Run under TZ=JST-9 like CI: the times below are UTC with
// microseconds, and one paging case passes a LOCAL DateTime.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  MessageStore store([String owner = 'owner-1']) =>
      h.open(owner: owner, key: key);

  group('reads', () {
    test('newest: the newest `limit`, oldest first, only that chat', () async {
      final s = store();
      await s.upsertAll([
        for (var i = 0; i < 10; i++) msg('m$i', t: i),
        msg('x1', conv: 'c2', t: 20),
      ]);
      expect(ids(await s.newest('c1', limit: 3)), ['m7', 'm8', 'm9']);
      expect(ids(await s.newest('c1')), [for (var i = 0; i < 10; i++) 'm$i']);
      expect(ids(await s.newest('c2')), ['x1']);
      expect(await s.newest('nope'), isEmpty);
    });

    test('older: strictly before, the closest `limit`, oldest first', () async {
      final s = store();
      await s.upsertAll([for (var i = 0; i < 10; i++) msg('m$i', t: i)]);
      expect(ids(await s.older('c1', at(6), limit: 3)), ['m3', 'm4', 'm5']);
      expect(ids(await s.older('c1', at(2))), ['m0', 'm1']);
      expect(await s.older('c1', at(0)), isEmpty);
    });

    test('older: a LOCAL `before` means the same instant (TZ=JST-9)', () async {
      final s = store();
      await s.upsertAll([for (var i = 0; i < 5; i++) msg('m$i', t: i)]);
      final local = at(3).toLocal();
      expect(ids(await s.older('c1', local)), ['m0', 'm1', 'm2']);
    });

    test('older: microsecond precision on the boundary', () async {
      final s = store();
      await s.upsertAll([msg('a', t: 0), msg('b', t: 1)]);
      // One microsecond after b: b is strictly older.
      final justAfter = at(1).add(const Duration(microseconds: 1));
      expect(ids(await s.older('c1', justAfter)), ['a', 'b']);
      expect(ids(await s.older('c1', at(1))), ['a']);
    });

    test(
      'around: the message plus up to `each` per side, oldest first',
      () async {
        final s = store();
        await s.upsertAll([
          for (var i = 0; i < 10; i++) msg('m$i', t: i),
          msg('x', conv: 'c2', t: 5),
        ]);
        expect(ids(await s.around('c1', 'm5', each: 2)), [
          'm3',
          'm4',
          'm5',
          'm6',
          'm7',
        ]);
        expect(ids(await s.around('c1', 'm1', each: 3)), [
          'm0',
          'm1',
          'm2',
          'm3',
          'm4',
        ]);
        expect(ids(await s.around('c1', 'm9', each: 2)), ['m7', 'm8', 'm9']);
        expect(await s.around('c1', 'missing'), isEmpty);
      },
    );
  });

  group('writes', () {
    test('upsertAll replaces by id', () async {
      final s = store();
      await s.upsertAll([msg('a', body: 'first')]);
      await s.upsertAll([msg('a', body: 'second')]);
      final got = await s.newest('c1');
      expect(ids(got), ['a']);
      expect(got.single.body, 'second');
    });

    test('upsertAll never stores a pending message', () async {
      final s = store();
      await s.upsertAll([
        msg('sending', sending: true),
        // A photo still uploading: local bytes, no attachment path yet.
        Message(
          id: 'uploading',
          conversationId: 'c1',
          senderId: 'u1',
          body: '',
          createdAt: at(1),
          localImage: Uint8List.fromList([1, 2, 3]),
        ),
        msg('stored', t: 2),
      ]);
      expect(ids(await s.newest('c1')), ['stored']);
    });

    test('remove deletes one message', () async {
      final s = store();
      await s.upsertAll([msg('a'), msg('b', t: 1)]);
      await s.remove('a');
      expect(ids(await s.newest('c1')), ['b']);
    });

    test(
      'deleteConversation removes its messages and sync state only',
      () async {
        final s = store();
        await s.reconcilePage('c1', [msg('a')], reachedStart: true);
        await s.reconcilePage('c2', [msg('b', conv: 'c2')], reachedStart: true);
        await s.deleteConversation('c1');
        expect(await s.newest('c1'), isEmpty);
        expect(await s.syncState('c1'), isNull);
        expect(ids(await s.newest('c2')), ['b']);
        expect(await s.syncState('c2'), isNotNull);
      },
    );
  });

  group('round trip', () {
    test(
      'every stored field survives; photo bytes and thumbPath do not',
      () async {
        final s = store();
        final full = Message(
          id: 'full',
          conversationId: 'c1',
          senderId: 'u1',
          body: 'Merhaba İstanbul 👋',
          createdAt: at(1),
          attachmentPath: 'c1/photo.jpg',
          attachmentPreview: Uint8List.fromList([9, 9, 9]),
          localImage: Uint8List.fromList([7, 7, 7]),
          deletion: MessageDeletion.placeholder,
          deletedBy: 'admin-1',
          editedAt: at(2),
          replyTo: 'm0',
          forwarded: true,
          poll: true,
          contact: true,
          file: const AttachedFile(
            name: 'report.pdf',
            mime: 'application/pdf',
            size: 123456,
            durationMs: 4200,
            thumbPath: '/tmp/thumb.jpg',
            waveform: 'AQID',
            transcript: 'said words',
          ),
          stickerId: 'sticker-1',
          albumCard: true,
          albumId: 'album-1',
          photoGroup: 'group-1',
          linkPreview: LinkPreview(
            url: Uri.parse('https://example.test/a?b=1'),
            title: 'Title',
            description: 'Desc',
            site: 'Example',
            imagePath: 'previews/a.jpg',
            video: true,
          ),
          adminMsg: const {
            'kind': 'notice',
            'n': 3,
            'nested': {
              'a': [1, 2],
            },
          },
        );
        await s.upsertAll([full]);
        final m = (await s.newest('c1')).single;
        expect(m.id, 'full');
        expect(m.conversationId, 'c1');
        expect(m.senderId, 'u1');
        expect(m.body, 'Merhaba İstanbul 👋');
        expect(m.createdAt.isAtSameMomentAs(at(1)), isTrue);
        expect(m.attachmentPath, 'c1/photo.jpg');
        expect(m.attachmentPreview, isNull);
        expect(m.localImage, isNull);
        expect(m.deletion, MessageDeletion.placeholder);
        expect(m.deletedBy, 'admin-1');
        expect(m.editedAt!.isAtSameMomentAs(at(2)), isTrue);
        expect(m.replyTo, 'm0');
        expect(m.forwarded, isTrue);
        expect(m.poll, isTrue);
        expect(m.contact, isTrue);
        expect(m.file!.name, 'report.pdf');
        expect(m.file!.mime, 'application/pdf');
        expect(m.file!.size, 123456);
        expect(m.file!.durationMs, 4200);
        expect(m.file!.thumbPath, isNull);
        expect(m.file!.waveform, 'AQID');
        expect(m.file!.transcript, 'said words');
        expect(m.stickerId, 'sticker-1');
        expect(m.albumCard, isTrue);
        expect(m.albumId, 'album-1');
        expect(m.photoGroup, 'group-1');
        expect(m.linkPreview!.url, Uri.parse('https://example.test/a?b=1'));
        expect(m.linkPreview!.title, 'Title');
        expect(m.linkPreview!.description, 'Desc');
        expect(m.linkPreview!.site, 'Example');
        expect(m.linkPreview!.imagePath, 'previews/a.jpg');
        expect(m.linkPreview!.video, isTrue);
        expect(jsonEncode(m.adminMsg), jsonEncode(full.adminMsg));
        expect(m.sending, isFalse);
      },
    );

    test(
      'a location (name and address live in the body) round-trips',
      () async {
        final s = store();
        await s.upsertAll([
          Message(
            id: 'loc',
            conversationId: 'c1',
            senderId: 'u1',
            body: 'Galata\nBeyoğlu',
            createdAt: at(1),
            location: const SharedLocation(
              lat: 41.0082,
              lng: 28.9784,
              name: 'Galata',
              address: 'Beyoğlu',
            ),
          ),
        ]);
        final m = (await s.newest('c1')).single;
        expect(m.location!.lat, 41.0082);
        expect(m.location!.lng, 28.9784);
        expect(m.location!.name, 'Galata');
        expect(m.location!.address, 'Beyoğlu');
      },
    );

    test('a plain message keeps its nulls and false flags', () async {
      final s = store();
      await s.upsertAll([msg('p', t: 3)]);
      final m = (await s.newest('c1')).single;
      expect(m.createdAt.isAtSameMomentAs(at(3)), isTrue);
      expect(m.deletion, isNull);
      expect(m.deletedBy, isNull);
      expect(m.editedAt, isNull);
      expect(m.replyTo, isNull);
      expect(m.forwarded || m.poll || m.contact || m.albumCard, isFalse);
      expect(m.location, isNull);
      expect(m.file, isNull);
      expect(m.stickerId, isNull);
      expect(m.albumId, isNull);
      expect(m.photoGroup, isNull);
      expect(m.linkPreview, isNull);
      expect(m.adminMsg, isNull);
      expect(m.attachmentPath, isNull);
    });

    test('vanished deletion round-trips', () async {
      final s = store();
      await s.upsertAll([msg('v', deletion: MessageDeletion.vanished)]);
      expect((await s.newest('c1')).single.deletion, MessageDeletion.vanished);
    });
  });

  group('reconcilePage', () {
    test(
      'reachedStart: keeps exactly the page, sets a complete block',
      () async {
        final s = store();
        await s.upsertAll([
          for (var i = 1; i <= 5; i++) msg('m$i', t: i),
          msg('other', conv: 'c2', t: 1),
        ]);
        await s.reconcilePage('c1', [
          msg('m2', t: 2),
          msg('m4', t: 4),
        ], reachedStart: true);
        expect(ids(await s.newest('c1')), ['m2', 'm4']);
        // Another chat is never touched.
        expect(ids(await s.newest('c2')), ['other']);
        final sync = (await s.syncState('c1'))!;
        expect(sync.complete, isTrue);
        expect(sync.contiguousFrom!.isAtSameMomentAs(at(2)), isTrue);
        expect(sync.newestAt!.isAtSameMomentAs(at(4)), isTrue);
      },
    );

    test(
      'not reachedStart: deletes only rows at or after the page oldest',
      () async {
        final s = store();
        await s.upsertAll([for (var i = 1; i <= 6; i++) msg('m$i', t: i)]);
        // The server no longer has m4 and m6 (deleted or hidden).
        await s.reconcilePage('c1', [
          msg('m3', t: 3, body: 'edited'),
          msg('m5', t: 5),
        ], reachedStart: false);
        final got = await s.newest('c1');
        expect(ids(got), ['m1', 'm2', 'm3', 'm5']);
        expect(got[2].body, 'edited');
        final sync = (await s.syncState('c1'))!;
        expect(sync.complete, isFalse);
        expect(sync.contiguousFrom!.isAtSameMomentAs(at(3)), isTrue);
        expect(sync.newestAt!.isAtSameMomentAs(at(5)), isTrue);
      },
    );

    test('a page overlapping the previous block extends it', () async {
      final s = store();
      await s.reconcilePage('c1', [
        for (var i = 1; i <= 4; i++) msg('m$i', t: i),
      ], reachedStart: false);
      await s.reconcilePage('c1', [
        for (var i = 3; i <= 6; i++) msg('m$i', t: i),
      ], reachedStart: false);
      final sync = (await s.syncState('c1'))!;
      expect(sync.contiguousFrom!.isAtSameMomentAs(at(1)), isTrue);
      expect(sync.newestAt!.isAtSameMomentAs(at(6)), isTrue);
      expect(sync.complete, isFalse);
      expect(ids(await s.newest('c1')), [for (var i = 1; i <= 6; i++) 'm$i']);
    });

    test('an overlapping page keeps a complete block complete', () async {
      final s = store();
      await s.reconcilePage('c1', [
        for (var i = 1; i <= 3; i++) msg('m$i', t: i),
      ], reachedStart: true);
      await s.reconcilePage('c1', [
        for (var i = 2; i <= 5; i++) msg('m$i', t: i),
      ], reachedStart: false);
      final sync = (await s.syncState('c1'))!;
      expect(sync.complete, isTrue);
      expect(sync.contiguousFrom!.isAtSameMomentAs(at(1)), isTrue);
      expect(ids(await s.newest('c1')), [for (var i = 1; i <= 5; i++) 'm$i']);
    });

    test('a page after a gap starts a new, incomplete block', () async {
      final s = store();
      await s.reconcilePage('c1', [
        for (var i = 1; i <= 3; i++) msg('m$i', t: i),
      ], reachedStart: true);
      // m4..m9 were never fetched: a gap.
      await s.reconcilePage('c1', [
        for (var i = 10; i <= 12; i++) msg('m$i', t: i),
      ], reachedStart: false);
      final sync = (await s.syncState('c1'))!;
      expect(sync.complete, isFalse);
      expect(sync.contiguousFrom!.isAtSameMomentAs(at(10)), isTrue);
      expect(sync.newestAt!.isAtSameMomentAs(at(12)), isTrue);
      // Rows older than the page are kept.
      expect(ids(await s.newest('c1')), [
        'm1',
        'm2',
        'm3',
        'm10',
        'm11',
        'm12',
      ]);
    });

    test('an empty page with reachedStart empties the chat', () async {
      final s = store();
      await s.upsertAll([msg('a'), msg('b', t: 1)]);
      await s.reconcilePage('c1', const [], reachedStart: true);
      expect(await s.newest('c1'), isEmpty);
      expect((await s.syncState('c1'))!.complete, isTrue);
    });

    test('syncState is null before anything is reconciled', () async {
      final s = store();
      await s.upsertAll([msg('a')]);
      expect(await s.syncState('c1'), isNull);
    });
  });

  group('search', () {
    Future<MessageStore> seeded() async {
      final s = store();
      await s.upsertAll([
        msg('tr1', t: 1, body: 'İstanbul’da buluşalım'),
        msg('tr2', t: 2, body: 'ISTANBUL çok güzel'),
        msg('tr3', conv: 'c2', t: 3, body: 'ıstanbul yazımı'),
        msg(
          'del',
          t: 4,
          body: 'istanbul silindi',
          deletion: MessageDeletion.placeholder,
        ),
        msg('ph1', t: 5, body: 'we will meet at the old bridge'),
        msg('ph2', t: 6, body: 'bridge the old gap'),
        msg('q', t: 7, body: 'she said "hello there" twice'),
      ]);
      return s;
    }

    test('folds İ/I/ı like the server, newest first, skips deleted', () async {
      final s = await seeded();
      expect(ids(await s.search('istanbul')), ['tr3', 'tr2', 'tr1']);
      expect(ids(await s.search('İSTANBUL')), ['tr3', 'tr2', 'tr1']);
    });

    test('matches substrings (trigram)', () async {
      final s = await seeded();
      expect(ids(await s.search('tanb')), ['tr3', 'tr2', 'tr1']);
      expect(ids(await s.search('ridg')), ['ph2', 'ph1']);
    });

    test('the query is one phrase, not loose words', () async {
      final s = await seeded();
      expect(ids(await s.search('the old bridge')), ['ph1']);
      expect(ids(await s.search('old bridge the')), isEmpty);
    });

    test('FTS syntax in the query is plain text, never an error', () async {
      final s = await seeded();
      expect(ids(await s.search('"hello there"')), ['q']);
      // An odd quote: only a correctly escaped phrase finds it.
      expect(ids(await s.search('said "hel')), ['q']);
      expect(await s.search('bridge OR gap'), isEmpty);
      expect(await s.search('bri*'), isEmpty);
      expect(await s.search('a:b NEAR(c d)'), isEmpty);
    });

    test('a query that is not searchable finds nothing', () async {
      final s = await seeded();
      expect(await s.search('is'), isEmpty);
      expect(await s.search('  i! '), isEmpty);
      expect(await s.search('😀😀😀'), isEmpty);
      expect(await s.search(''), isEmpty);
    });

    test('conversationId and limit restrict the result', () async {
      final s = await seeded();
      expect(ids(await s.search('istanbul', conversationId: 'c1')), [
        'tr2',
        'tr1',
      ]);
      expect(ids(await s.search('istanbul', limit: 1)), ['tr3']);
    });

    test('the index follows edits, removals and deleted chats', () async {
      final s = await seeded();
      await s.upsertAll([msg('ph1', t: 5, body: 'now about ferries')]);
      expect(ids(await s.search('bridge')), ['ph2']);
      expect(ids(await s.search('ferries')), ['ph1']);
      await s.remove('ph2');
      expect(await s.search('bridge'), isEmpty);
      await s.deleteConversation('c2');
      expect(ids(await s.search('istanbul')), ['tr2', 'tr1']);
      // Deleted for everyone after it was indexed.
      await s.upsertAll([
        msg(
          'tr2',
          t: 2,
          body: 'ISTANBUL çok güzel',
          deletion: MessageDeletion.placeholder,
        ),
      ]);
      expect(ids(await s.search('istanbul')), ['tr1']);
      await s.reconcilePage('c1', [msg('ph1', t: 5)], reachedStart: true);
      expect(await s.search('istanbul'), isEmpty);
    });
  });

  group('cursor', () {
    test('null on a fresh store, then the last saved one', () async {
      final s = store();
      expect(await s.cursor(), isNull);
      await s.saveCursor(ChangeCursor(at(1), 'id-1'));
      await s.saveCursor(ChangeCursor(at(2), 'id-2'));
      final c = (await s.cursor())!;
      expect(c.id, 'id-2');
      expect(c.updatedAt.isAtSameMomentAs(at(2)), isTrue);
    });

    test('survives a cold reopen, with microseconds', () async {
      await store().saveCursor(ChangeCursor(at(3), 'id-3'));
      final c = (await store().cursor())!;
      expect(c.id, 'id-3');
      expect(c.updatedAt.microsecondsSinceEpoch, at(3).microsecondsSinceEpoch);
    });
  });

  group('encryption at rest', () {
    test('the file on disk is not plain SQLite and needs the key', () async {
      final s = store();
      await s.upsertAll([
        for (var i = 0; i < 200; i++) msg('m$i', t: i, body: 'secret text $i'),
      ]);
      await s.saveCursor(ChangeCursor(at(1), 'c'));
      expect(await h.file.exists(), isTrue);
      final head = await h.file.openRead(0, 16).expand((b) => b).toList();
      expect(head.length, 16, reason: 'the database header is on disk');
      expect(
        ascii.decode(head.sublist(0, 15), allowInvalid: true),
        isNot('SQLite format 3'),
      );
      for (final f in [h.file, h.wal]) {
        if (!await f.exists()) continue;
        final bytes = await f.readAsBytes();
        expect(
          latin1.decode(bytes).contains('secret text'),
          isFalse,
          reason: '${f.path} holds plain text',
        );
      }
      // Opened without the key, the file is unreadable.
      final raw = sql.sqlite3.open(h.file.path);
      addTearDown(raw.close);
      expect(
        () => raw.select('SELECT count(*) FROM sqlite_master'),
        throwsA(isA<sql.SqliteException>()),
      );
    });

    test('reopening with the same key and owner reads the data', () async {
      await store().upsertAll([msg('kept')]);
      expect(ids(await store().newest('c1')), ['kept']);
    });
  });

  group('failure modes recreate the database once', () {
    test('wrong key: empty, never throws, and usable again', () async {
      await store().upsertAll([msg('old')]);
      final other = await h.newKey();
      final s = h.open(owner: 'owner-1', key: other);
      expect(await s.newest('c1'), isEmpty);
      await s.upsertAll([msg('new')]);
      expect(ids(await s.newest('c1')), ['new']);
      // A cold reopen with that key finds the recreated database.
      expect(ids(await h.open(owner: 'owner-1', key: other).newest('c1')), [
        'new',
      ]);
    });

    test('other owner: never sees the data, and starts empty', () async {
      final a = store('owner-1');
      await a.upsertAll([msg('mine')]);
      await a.saveCursor(ChangeCursor(at(1), 'cur'));
      await a.reconcilePage('c1', [msg('mine')], reachedStart: true);
      final b = store('owner-2');
      expect(await b.newest('c1'), isEmpty);
      expect(await b.search('hello'), isEmpty);
      expect(await b.cursor(), isNull);
      expect(await b.syncState('c1'), isNull);
      await b.upsertAll([msg('theirs')]);
      expect(ids(await b.newest('c1')), ['theirs']);
      // Owner 2 now owns the file: a cold reopen as owner 2 keeps it.
      expect(ids(await store('owner-2').newest('c1')), ['theirs']);
    });

    test('corrupt file: empty, never throws, and usable again', () async {
      await h.file.writeAsBytes(
        List<int>.generate(64 * 1024, (i) => (i * 31 + 7) & 0xff),
      );
      final s = store();
      expect(await s.newest('c1'), isEmpty);
      expect(await s.cursor(), isNull);
      await s.upsertAll([msg('fresh')]);
      expect(ids(await s.newest('c1')), ['fresh']);
    });

    test('a file corrupted after use is recreated on the next open', () async {
      await store().upsertAll([msg('old')]);
      final len = await h.file.length();
      final raf = await h.file.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(0);
      await raf.writeFrom(List<int>.filled(len, 0x5a));
      await raf.close();
      if (await h.wal.exists()) await h.wal.writeAsBytes([1, 2, 3]);
      final s = store();
      expect(await s.newest('c1'), isEmpty);
      await s.upsertAll([msg('fresh')]);
      expect(ids(await s.newest('c1')), ['fresh']);
    });
  });

  group('clear', () {
    test('deletes the file, -wal and -shm, and the key', () async {
      final s = store();
      await s.upsertAll([msg('a')]);
      await s.saveCursor(ChangeCursor(at(1), 'x'));
      expect(await h.file.exists(), isTrue);
      await s.clear();
      expect(await h.file.exists(), isFalse);
      expect(await h.wal.exists(), isFalse);
      expect(await h.shm.exists(), isFalse);
      expect(h.deleteKeyCalls, 1);
    });

    test('also deletes leftover -wal and -shm files', () async {
      final s = store();
      await s.upsertAll([msg('a')]);
      // Left behind by a crash (or a WAL-mode open): clear must not keep them.
      await h.wal.writeAsBytes([1, 2, 3]);
      await h.shm.writeAsBytes([4, 5, 6]);
      await s.clear();
      expect(await h.file.exists(), isFalse);
      expect(await h.wal.exists(), isFalse);
      expect(await h.shm.exists(), isFalse);
    });

    test('clear racing writes and reads never throws', () async {
      final s = store();
      await s.upsertAll([msg('a')]);
      final work = <Future<Object?>>[
        s.upsertAll([msg('b', t: 1)]),
        s.saveCursor(ChangeCursor(at(1), 'x')),
        s.clear(),
        s.newest('c1'),
        s.upsertAll([msg('c', t: 2)]),
        s.search('hello'),
      ];
      await expectLater(Future.wait(work), completes);
      expect(h.deleteKeyCalls, 1);
    });
  });
}

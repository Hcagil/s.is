// DriftReadMarkStore over a REAL encrypted store file, written from the
// ReadMarkStore contract (lib/features/chat/domain/read_mark_store.dart) and
// the seen-marks-offline brief, never from the implementation. Includes the
// store schema upgrade 1 -> 3 on a real file made by the production store.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_read_mark_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/read_marks.dart';

import 'store_harness.dart';

/// A mark as what it says; ReadMark promises no value equality.
List<(String, bool, DateTime?, DateTime?)> rows(List<ReadMark> marks) =>
    [for (final m in marks) (m.userId, m.shares, m.readAt, m.deliveredAt)]
      ..sort((a, b) => a.$1.compareTo(b.$1));

void main() {
  late StoreHarness h;
  late String key;
  final opened = <DriftMessageStore>[];

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    opened.clear();
    addTearDown(() async {
      for (final s in opened) {
        await s.close();
      }
    });
  });

  DriftMessageStore messages([String owner = 'owner-1']) {
    final s = h.open(owner: owner, key: key);
    opened.add(s);
    return s;
  }

  // Whole-millisecond times here; microsecond precision has its own test.
  DateTime ms(int n) => DateTime.utc(2026, 3, 1, 9, n);
  final marks = [
    ReadMark(userId: 'u2', shares: true, readAt: ms(3), deliveredAt: ms(4)),
    const ReadMark(userId: 'u3', shares: false),
    ReadMark(userId: 'u4', shares: false, deliveredAt: ms(2)),
    ReadMark(userId: 'u5', shares: true, readAt: ms(1)),
  ];

  group('round trip', () {
    test('every field comes back, null and set, shares false', () async {
      final s = DriftReadMarkStore(messages());
      await s.save('c1', marks);

      expect(rows(await s.load('c1')), rows(marks));
    });

    test('survives closing and reopening the file', () async {
      final first = messages();
      await DriftReadMarkStore(first).save('c1', marks);
      await first.close();

      expect(
        rows(await DriftReadMarkStore(messages()).load('c1')),
        rows(marks),
      );
    });

    test('times keep their exact instant, so the newest message still shows '
        'delivered and read offline', () async {
      // delivered_at is max(created_at) of the conversation: equal to the
      // newest message's time, to the microsecond (at() has microseconds). Lose precision and that
      // message falls just after the mark: its tick is gone offline.
      final sent = at(7);
      final s = DriftReadMarkStore(messages());
      await s.save('c1', [
        ReadMark(userId: 'u2', shares: true, readAt: sent, deliveredAt: sent),
      ]);
      final back = (await s.load('c1')).single;

      expect(back.hasDelivered(sent), isTrue, reason: 'delivered tick lost');
      expect(back.hasRead(sent), isTrue, reason: 'seen tick lost');
      expect(back.deliveredAt, sent);
      expect(back.readAt, sent);
    });
  });

  test('save replaces ALL stored marks of the conversation', () async {
    final s = DriftReadMarkStore(messages());
    await s.save('c1', marks);
    await s.save('c1', const [ReadMark(userId: 'u2', shares: false)]);

    expect(rows(await s.load('c1')), [('u2', false, null, null)]);
  });

  test('save of an empty list leaves nothing stored', () async {
    final s = DriftReadMarkStore(messages());
    await s.save('c1', marks);
    await s.save('c1', const []);

    expect(await s.load('c1'), isEmpty);
  });

  test('other conversations are untouched', () async {
    final s = DriftReadMarkStore(messages());
    await s.save('c1', marks);
    await s.save('c2', [ReadMark(userId: 'u9', shares: true, readAt: ms(9))]);
    await s.save('c2', const []);

    expect(rows(await s.load('c1')), rows(marks));
  });

  test('an unknown conversation is empty', () async {
    final s = DriftReadMarkStore(messages());
    await s.save('c1', marks);

    expect(await s.load('nope'), isEmpty);
  });

  test('no account (empty owner): load empty, save does not throw', () async {
    final s = DriftReadMarkStore(messages(''));

    await s.save('c1', marks);
    expect(await s.load('c1'), isEmpty);
  });

  test('a closed store: load empty, save does not throw', () async {
    final m = messages();
    final s = DriftReadMarkStore(m);
    await s.save('c1', marks);
    await m.close();

    await expectLater(s.save('c1', marks), completes);
    expect(await s.load('c1'), isEmpty);
  });

  group('sign-out erases', () {
    test('clear() removes stored marks; the next account sees none', () async {
      final ann = messages('ann');
      await DriftReadMarkStore(ann).save('c1', marks);
      await ann.clear();
      expect(h.file.existsSync(), isFalse, reason: 'file not erased');

      final bob = DriftReadMarkStore(messages('bob'));
      expect(await bob.load('c1'), isEmpty, reason: "ann's marks leaked");
    });

    test('another account on the same file never sees the marks', () async {
      final ann = messages('ann');
      await DriftReadMarkStore(ann).save('c1', marks);
      await ann.close();

      expect(await DriftReadMarkStore(messages('bob')).load('c1'), isEmpty);
    });
  });

  group('schema upgrade 1 -> 3', () {
    test('a fresh install has read_marks', () async {
      final s = DriftReadMarkStore(messages());
      await s.save('c1', marks);
      expect(rows(await s.load('c1')), rows(marks));
    });

    test('a real v1 file keeps messages, search, sync state, list and meta, '
        'and gets a usable read_marks', () async {
      // A real file made by the production store, put back in its exact v1
      // shape: v2 added read_marks, v3 olm_sessions and send_queue.
      final v1 = messages();
      await v1.reconcilePage('c1', [
        msg('m1', t: 1, body: 'kahvaltı hazır'),
        msg('m2', t: 2, body: 'geliyorum'),
      ], reachedStart: true);
      await v1.saveCursor(ChangeCursor(at(2), 'm2'));
      await DriftChatListSnapshotStore(v1)
          .save('owner-1', const [Conversation(id: 'c1', title: 'Aile')]);
      await v1.run<void>(null, (db) async {
        await db.customStatement('DROP TABLE read_marks');
        await db.customStatement('DROP TABLE olm_sessions');
        await db.customStatement('DROP TABLE send_queue');
        await db.customStatement('PRAGMA user_version = 1');
      });
      await v1.close();

      final v2 = messages();
      expect(
        ids(await v2.newest('c1')),
        unorderedEquals(['m1', 'm2']),
        reason: 'messages lost',
      );
      expect(ids(await v2.search('kahvaltı')), ['m1'], reason: 'FTS lost');
      expect(await v2.syncState('c1'), isNotNull, reason: 'sync_state lost');
      expect((await v2.cursor())?.id, 'm2', reason: 'meta lost');
      expect(
        (await DriftChatListSnapshotStore(v2).load('owner-1'))
            ?.map((c) => c.id),
        ['c1'],
        reason: 'conversations lost',
      );
      final version = await v2.run<int>(-1, (db) async {
        final r = await db.customSelect('PRAGMA user_version').getSingle();
        return r.read<int>('user_version');
      });
      expect(version, 4, reason: 'not upgraded to the current schema');

      final s = DriftReadMarkStore(v2);
      await s.save('c1', marks);
      expect(rows(await s.load('c1')), rows(marks), reason: 'no read_marks');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_read_mark_store.dart';
import 'package:sis/features/crypto/data/drift_olm_pickle_store.dart';
import 'package:sis/features/chat/data/store/drift_send_queue_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';

import 'store_harness.dart';

List<(String, bool, DateTime?, DateTime?)> rows(List<ReadMark> marks) =>
    [for (final m in marks) (m.userId, m.shares, m.readAt, m.deliveredAt)]
      ..sort((a, b) => a.$1.compareTo(b.$1));

Future<Set<String>> tables(DriftMessageStore s) =>
    s.run<Set<String>>({}, (db) async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      return {for (final r in rows) r.read<String>('name')};
    });

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

  DateTime ms(int n) => DateTime.utc(2026, 3, 1, 9, n);

  final marks = [
    ReadMark(userId: 'u2', shares: true, readAt: ms(3), deliveredAt: ms(4)),
    const ReadMark(userId: 'u3', shares: false),
  ];

  test('a real v2 file keeps messages, search, sync state, list, meta olm_account and read_marks, and gets usable olm_sessions and send_queue', () async {
    final v2 = messages();
    await v2.reconcilePage('c1', [
      msg('m1', t: 1, body: 'kahvaltı hazır'),
      msg('m2', t: 2, body: 'geliyorum'),
    ], reachedStart: true);
    await v2.saveCursor(ChangeCursor(at(2), 'm2'));
    await DriftChatListSnapshotStore(v2)
        .save('owner-1', const [Conversation(id: 'c1', title: 'Aile')]);
    await DriftReadMarkStore(v2).save('c1', marks);
    await DriftOlmPickleStore(v2).save('pickle-v2');
    await v2.run<void>(null, (db) async {
      await db.customStatement('DROP TABLE olm_sessions');
      await db.customStatement('DROP TABLE send_queue');
      await db.customStatement('PRAGMA user_version = 2');
    });
    await v2.close();

    final v3 = messages();

    expect(
      ids(await v3.newest('c1')),
      unorderedEquals(['m1', 'm2']),
      reason: 'messages lost',
    );
    expect(ids(await v3.search('kahvaltı')), ['m1'], reason: 'FTS lost');
    expect(await v3.syncState('c1'), isNotNull, reason: 'sync_state lost');
    expect((await v3.cursor())?.id, 'm2', reason: 'meta lost');
    expect(
      (await DriftChatListSnapshotStore(v3).load('owner-1'))?.map((c) => c.id),
      ['c1'],
      reason: 'conversations lost',
    );

    expect(
      await DriftOlmPickleStore(v3).load(),
      'pickle-v2',
      reason: 'meta olm_account lost',
    );
    expect(
      rows(await DriftReadMarkStore(v3).load('c1')),
      rows(marks),
      reason: 'read_marks lost',
    );

    final version = await v3.run<int>(-1, (db) async {
      final r = await db.customSelect('PRAGMA user_version').getSingle();
      return r.read<int>('user_version');
    });
    expect(version, 3);

    final tableSet = await tables(v3);
    expect(tableSet.contains('olm_sessions'), isTrue);
    expect(tableSet.contains('send_queue'), isTrue);

    // Test send_queue
    final sqStore = DriftSendQueueStore(v3);
    final record = QueuedRecord(
      id: 'q1',
      conversationId: 'c1',
      createdAt: ms(5),
      body: 'hello',
    );
    await sqStore.save('u1', [record]);
    final loaded = await sqStore.load('u1');
    expect(loaded.map((r) => r.id), ['q1']);
    expect(loaded.single.body, 'hello');

    await sqStore.setCiphertext('u1', 'q1', 'cipher', 1);
    final ct = await sqStore.ciphertextOf('u1', 'q1');
    expect(ct, isNotNull);
    expect(ct!.ciphertext, 'cipher');
    expect(ct.olmType, 1);

    // Test olm_sessions
    await v3.run<void>(null, (db) async {
      await db.customStatement(
        "INSERT INTO olm_sessions(session_id, peer_user_id, peer_identity_key, pickle, last_used_at) VALUES ('s1','u2','ik','p',1)",
      );
    });
    final count = await v3.run<int>(-1, (db) async {
      final r = await db
          .customSelect('SELECT COUNT(*) AS c FROM olm_sessions')
          .getSingle();
      return r.read<int>('c');
    });
    expect(count, 1);
  });

  test('a real v1 file gets all three new tables', () async {
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

    final v3b = messages();

    expect(ids(await v3b.newest('c1')), unorderedEquals(['m1', 'm2']));
    expect(ids(await v3b.search('kahvaltı')), ['m1']);
    expect(await v3b.syncState('c1'), isNotNull);
    expect((await v3b.cursor())?.id, 'm2');
    expect(
      (await DriftChatListSnapshotStore(v3b).load('owner-1'))?.map((c) => c.id),
      ['c1'],
    );

    final version2 = await v3b.run<int>(-1, (db) async {
      final r = await db.customSelect('PRAGMA user_version').getSingle();
      return r.read<int>('user_version');
    });
    expect(version2, 3);

    final tableSet2 = await tables(v3b);
    expect(tableSet2.contains('read_marks'), isTrue);
    expect(tableSet2.contains('olm_sessions'), isTrue);
    expect(tableSet2.contains('send_queue'), isTrue);

    // Read marks round trip
    final rmStore = DriftReadMarkStore(v3b);
    await rmStore.save('c1', marks);
    expect(rows(await rmStore.load('c1')), rows(marks));
  });

  test('a fresh install is version 3 with the new tables', () async {
    final fresh = messages();

    final version3 = await fresh.run<int>(-1, (db) async {
      final r = await db.customSelect('PRAGMA user_version').getSingle();
      return r.read<int>('user_version');
    });
    expect(version3, 3);

    final tableSet3 = await tables(fresh);
    expect(tableSet3.contains('olm_sessions'), isTrue);
    expect(tableSet3.contains('send_queue'), isTrue);
  });
}

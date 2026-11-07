// ChatListWithPushStore.loadWithPush on DriftChatListSnapshotStore over a
// REAL encrypted store file (StoreHarness). Written from the contract (slice
// 1, t_f79a5084b0), never from the implementation:
// - one call returns the saved list and the push-inbox rows (oldest first);
//   load(owner) == loadWithPush(owner)?.list;
// - a different owner: null, the store is not touched (no file, no key read);
// - nothing saved (no meta row): null;
// - conversations come back ordered by sort_at;
// - a corrupt conversation row: snapshot cleared, null, push rows not given;
// - the push read fails: the list still comes back, push empty;
// - marks snap-read-start / snap-read-done / snap-decoded (once per process,
//   so the mark test is FIRST in this file).
import 'package:flutter/foundation.dart' show debugPrint, DebugPrintCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';

import 'store_harness.dart';

int _rx(int n) => base.add(Duration(seconds: n)).microsecondsSinceEpoch;

Future<void> _putInbox(DriftMessageStore s, String id, int t) =>
    s.run<void>(null, (db) async {
      await db.customStatement(
        'INSERT INTO push_inbox(message_id, conversation_id, sender_id, body, '
        'sealed, received_at) VALUES (?, ?, ?, ?, ?, ?)',
        [id, 'c1', 'alice', 'push $id', 'ab' * 32, _rx(t)],
      );
    }, write: true);

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  final convs = [
    Conversation(id: 'c1', title: 'Aile', lastMessageAt: at(5)),
    Conversation(id: 'c2', title: 'Work', lastMessageAt: at(2)),
    const Conversation(id: 'c3'),
  ];

  List<String> cids(List<Conversation>? l) => [for (final c in l!) c.id];

  DriftMessageStore open([String owner = 'owner-1']) {
    final s = h.open(owner: owner, key: key);
    addTearDown(s.close);
    return s;
  }

  test('marks snap-read-start, snap-read-done, snap-decoded once', () async {
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    await snap.save('owner-1', convs);
    final lines = <String>[];
    final DebugPrintCallback saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) lines.add(m);
    };
    addTearDown(() => debugPrint = saved);
    await snap.loadWithPush('owner-1');
    await snap.loadWithPush('owner-1');
    for (final label in ['snap-read-start', 'snap-read-done', 'snap-decoded']) {
      expect(
        lines.where((l) => l.startsWith('sis.startup $label ')),
        hasLength(1),
        reason: label,
      );
    }
  });

  test('one call returns the list and the push rows, oldest first; '
      'load() is its list', () async {
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    expect(snap, isA<ChatListWithPushStore>());
    await snap.save('owner-1', convs);
    await _putInbox(s, 'n2', 2);
    await _putInbox(s, 'n1', 1);
    final got = await snap.loadWithPush('owner-1');
    expect(got, isNotNull);
    expect(cids(got!.list), ['c1', 'c2', 'c3']);
    expect(ids(got.push), ['n1', 'n2']);
    expect(got.push.first.body, 'push n1');
    expect(cids(await snap.load('owner-1')), ['c1', 'c2', 'c3']);
  });

  test('a different owner: null, and the store is not opened', () async {
    var keyReads = 0;
    final s = DriftMessageStore(
      ownerId: 'owner-1',
      file: () async => h.file,
      key: () async {
        keyReads++;
        return key;
      },
      deleteKey: () async {},
    );
    addTearDown(s.close);
    expect(await DriftChatListSnapshotStore(s).loadWithPush('owner-2'), isNull);
    expect(h.file.existsSync(), isFalse, reason: 'no file was made');
    expect(keyReads, 0, reason: 'the store was not opened');
  });

  test('push rows but no saved list (no meta row): null', () async {
    final s = open();
    await _putInbox(s, 'n1', 1);
    expect(await DriftChatListSnapshotStore(s).loadWithPush('owner-1'), isNull);
  });

  test('conversations follow sort_at, not insert order', () async {
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    await snap.save('owner-1', convs);
    // Reverse the stored order: sort_at decides, rowid order must not.
    await s.run<void>(null, (db) async {
      await db.customStatement('UPDATE conversations SET sort_at = -sort_at');
    }, write: true);
    expect(cids((await snap.loadWithPush('owner-1'))!.list), [
      'c3',
      'c2',
      'c1',
    ]);
  });

  test(
    'a corrupt conversation row: cleared, null, push rows not given',
    () async {
      final s = open();
      final snap = DriftChatListSnapshotStore(s);
      await snap.save('owner-1', convs);
      await _putInbox(s, 'n1', 1);
      await s.run<void>(null, (db) async {
        await db.customStatement(
          "UPDATE conversations SET json = '{\"x\":[' WHERE id = 'c2'",
        );
      }, write: true);
      expect(await snap.loadWithPush('owner-1'), isNull);
      final left = await s.run<int>(
        -1,
        (db) async =>
            (await db.customSelect('SELECT 1 FROM conversations').get()).length,
      );
      expect(left, 0, reason: 'the broken snapshot is cleared');
      expect(await snap.loadWithPush('owner-1'), isNull);
    },
  );

  test('the push read fails: the list still comes back, push empty', () async {
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    await snap.save('owner-1', convs);
    await _putInbox(s, 'n1', 1);
    await s.run<void>(null, (db) async {
      await db.customStatement('DROP TABLE push_inbox');
    }, write: true);
    final got = await snap.loadWithPush('owner-1');
    expect(got, isNotNull);
    expect(cids(got!.list), ['c1', 'c2', 'c3']);
    expect(got.push, isEmpty);
  });
}

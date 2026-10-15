// DriftChatListSnapshotStore over a REAL encrypted store file, written from
// the ChatListSnapshotStore contract
// (lib/features/chat/domain/chat_list_snapshot_store.dart) and the Private
// Chats step 1 brief, never from the implementation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message_store.dart';

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  DriftMessageStore messages([String owner = 'owner-1']) =>
      h.open(owner: owner, key: key);

  final convs = [
    Conversation(
      id: 'c1',
      title: 'Aile',
      lastMessage: 'Akşam görüşürüz',
      lastMessageAt: at(5),
      lastSenderId: 'u2',
      unread: 3,
      other: const Member(userId: 'u2', displayName: 'Ayşe', tag: 'ayse'),
    ),
    Conversation(id: 'c2', title: 'Work', lastMessageAt: at(2)),
    const Conversation(id: 'c3'),
  ];

  void expectSame(List<Conversation>? got, List<Conversation> want) {
    expect(got, isNotNull);
    expect([for (final c in got!) c.id], [for (final c in want) c.id]);
    for (var i = 0; i < want.length; i++) {
      final a = got[i], e = want[i];
      expect(a.title, e.title);
      expect(a.lastMessage, e.lastMessage);
      expect(a.lastSenderId, e.lastSenderId);
      expect(a.unread, e.unread);
      if (e.lastMessageAt == null) {
        expect(a.lastMessageAt, isNull);
      } else {
        expect(a.lastMessageAt!.isAtSameMomentAs(e.lastMessageAt!), isTrue);
      }
      expect(a.other?.userId, e.other?.userId);
      expect(a.other?.displayName, e.other?.displayName);
    }
  }

  test('nothing saved loads as null', () async {
    expect(
      await DriftChatListSnapshotStore(messages()).load('owner-1'),
      isNull,
    );
  });

  test('save then load keeps order and fields, also after reopen', () async {
    await DriftChatListSnapshotStore(messages()).save('owner-1', convs);
    expectSame(
      await DriftChatListSnapshotStore(messages()).load('owner-1'),
      convs,
    );
  });

  test('a saved empty list loads as [], not null', () async {
    final s = DriftChatListSnapshotStore(messages());
    await s.save('owner-1', convs);
    await s.save('owner-1', const []);
    expect(await s.load('owner-1'), isEmpty);
    expect(await s.load('owner-1'), isNotNull);
  });

  test('save replaces the previous list', () async {
    final s = DriftChatListSnapshotStore(messages());
    await s.save('owner-1', convs);
    await s.save('owner-1', [convs[2], convs[0]]);
    expectSame(await s.load('owner-1'), [convs[2], convs[0]]);
  });

  test('a different owner: load is null and save does nothing', () async {
    final s = DriftChatListSnapshotStore(messages('owner-1'));
    await s.save('owner-1', convs);
    expect(await s.load('owner-2'), isNull);
    await s.save('owner-2', [convs[1]]);
    expectSame(await s.load('owner-1'), convs);
  });

  test('the file of another owner never leaks its list', () async {
    await DriftChatListSnapshotStore(messages('owner-1'))
        .save('owner-1', convs);
    final other = DriftChatListSnapshotStore(messages('owner-2'));
    expect(await other.load('owner-2'), isNull);
    expect(await other.load('owner-1'), isNull);
  });

  test('clear removes the snapshot', () async {
    final s = DriftChatListSnapshotStore(messages());
    await s.save('owner-1', convs);
    await s.clear();
    expect(await s.load('owner-1'), isNull);
  });

  test('corrupt stored data is cleared and loads as null', () async {
    final store = messages();
    final s = DriftChatListSnapshotStore(store);
    await s.save('owner-1', convs);
    final snapshotTables = <String>[];
    // Overwrite every text column of the snapshot table with broken JSON.
    final broke = await store.run<int>(0, (db) async {
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name LIKE '%conversation%'",
          )
          .get();
      var n = 0;
      for (final t in tables) {
        final name = t.read<String>('name');
        snapshotTables.add(name);
        final cols = await db.customSelect('PRAGMA table_info("$name")').get();
        for (final c in cols) {
          final col = c.read<String>('name');
          final type = c.read<String>('type').toUpperCase();
          if (col == 'id' || col == 'owner_id' || !type.contains('TEXT')) {
            continue;
          }
          n += await db.customUpdate('UPDATE "$name" SET "$col" = \'{"x":[\'');
        }
      }
      return n;
    });
    expect(broke, greaterThan(0), reason: 'found the snapshot rows');
    expect(await s.load('owner-1'), isNull);
    // Cleared: the broken rows are gone from the file, not just skipped.
    final left = await store.run<int>(-1, (db) async {
      var n = 0;
      for (final t in snapshotTables) {
        n += (await db.customSelect('SELECT 1 FROM "$t"').get()).length;
      }
      return n;
    });
    expect(left, 0);
    expect(await s.load('owner-1'), isNull);
    // A fresh save works again.
    await s.save('owner-1', [convs[1]]);
    expectSame(await s.load('owner-1'), [convs[1]]);
  });

  group('seams with the message store', () {
    test('deleteConversation drops that chat from the list', () async {
      final MessageStore store = messages();
      final s = DriftChatListSnapshotStore(store as DriftMessageStore);
      await s.save('owner-1', convs);
      await store.deleteConversation('c1');
      expectSame(await s.load('owner-1'), [convs[1], convs[2]]);
    });

    test('clear and save running at the same time never throw', () async {
      final store = messages();
      final s = DriftChatListSnapshotStore(store);
      await s.save('owner-1', convs);
      await expectLater(
        Future.wait<Object?>([
          s.save('owner-1', [convs[0]]),
          store.clear(),
          s.save('owner-1', [convs[1]]),
          s.load('owner-1'),
        ]),
        completes,
      );
      expect(h.deleteKeyCalls, 1);
    });

    test('after clear, a reopened store has no list', () async {
      final store = messages();
      await DriftChatListSnapshotStore(store).save('owner-1', convs);
      await store.clear();
      expect(
        await DriftChatListSnapshotStore(messages()).load('owner-1'),
        isNull,
      );
    });
  });
}

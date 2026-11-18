import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/conversation.dart';

import 'store_harness.dart';

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    DriftMessageStore.resetPrefetchForTest();
    addTearDown(DriftMessageStore.resetPrefetchForTest);
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

  Future<void> seed() async {
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    await snap.save('owner-1', convs);
    await s.close();
    DriftMessageStore.resetPrefetchForTest(); // <‑‑ added line
  }

  test('preload used, no second read – custom preload', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => key);
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        return (list: [const Conversation(id: 'pre')], push: <Message>[]);
      },
    );
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    final got = await snap.loadWithPush('owner-1');
    expect(got, isNotNull);
    expect(cids(got!.list), ['pre']);
    expect(got.push, isEmpty);
  });

  test('preload used, no second read – real snapshot preload', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => key);
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        return await DriftChatListSnapshotStore.readSnapshot(db);
      },
    );
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    final got = await snap.loadWithPush('owner-1');
    expect(got, isNotNull);
    expect(cids(got!.list), ['c1', 'c2', 'c3']);
  });

  test('no warmOpen – normal read', () async {
    await seed();
    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    final got = await snap.loadWithPush('owner-1');
    expect(got, isNotNull);
    expect(cids(got!.list), ['c1', 'c2', 'c3']);
  });

  test('different owner – preload present but owner mismatch', () async {
    await seed();
    await DriftMessageStore.prefetchKey(() async => key);
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        return (list: [const Conversation(id: 'pre')], push: <Message>[]);
      },
    );
    final s = open(); // store is owner-1
    final snap = DriftChatListSnapshotStore(s);
    final got = await snap.loadWithPush('owner-2'); // request for owner-2
    expect(got, isNull);
  });

  test('corrupt row – preload does not clear, normal read clears', () async {
    await seed();
    // corrupt a row
    final sCorrupt = open();
    await sCorrupt.run<void>(null, (db) async {
      await db.customStatement(
        "UPDATE conversations SET json = '{\"x\":[' WHERE id = 'c2'",
      );
    }, write: true);
    await sCorrupt.close();
    DriftMessageStore.resetPrefetchForTest();
    await DriftMessageStore.prefetchKey(() async => key);

    int rowsAfter = 0;
    await DriftMessageStore.warmOpen(
      () async => h.file,
      preload: (db) async {
        final r = await DriftChatListSnapshotStore.readSnapshot(db);
        rowsAfter =
            (await db.customSelect('SELECT 1 FROM conversations').get()).length;
        return r;
      },
    );

    final s = open();
    final snap = DriftChatListSnapshotStore(s);
    final got = await snap.loadWithPush('owner-1');
    expect(got, isNull);
    expect(rowsAfter, 3); // preload did not clear

    // second load should clear
    final got2 = await snap.loadWithPush('owner-1');
    expect(got2, isNull);
    final left = await s.run<int>(
      -1,
      (db) async =>
          (await db.customSelect('SELECT 1 FROM conversations').get()).length,
    );
    expect(left, 0);
  });
}

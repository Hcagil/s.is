// push_inbox (slice 2: the notification saves an opened private message) on a
// REAL SQLite3 Multiple Ciphers store made by the production drift schema.
// Written from the contract (t_0f04c69ee7 design, t_428ad7c883 QA contract),
// never from the implementation:
// - schema 5: push_inbox(message_id PK, conversation_id, sender_id, body,
//   sealed, received_at micros); triggers push_inbox_ai / push_inbox_au on
//   messages delete the inbox row of that id; 1..4 -> 5 creates both,
//   re-runnable;
// - PushInboxStore: pushInbox() = all rows oldest first as Message
//   (createdAt = received_at); sweepPushInbox(before) deletes received_at <
//   before;
// - deleteConversation, the list snapshot save() (chats not in the list),
//   snapshot clear() and the store clear() delete inbox rows;
// - inbox rows never enter messages, so a held chat's reconcile is unchanged.
// Run under TZ=JST-9 like CI.
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sis/features/chat/domain/push_inbox_store.dart';
import 'package:sis/features/crypto/data/drift_security_code_store.dart';
import 'package:sis/features/crypto/data/olm_key_engine.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import 'store_harness.dart';

final class _FixedPickleKey implements PickleKeyStore {
  @override
  Future<List<int>> loadOrCreate() async => List<int>.filled(32, 7);
  @override
  Future<void> delete() async {}
}

/// received_at of inbox row n: n seconds after [base], in microseconds.
int rx(int n) => base.add(Duration(seconds: n)).microsecondsSinceEpoch;

Future<void> putInbox(
  DriftMessageStore s,
  String id, {
  String conv = 'c1',
  String sender = 'alice',
  String body = 'from push',
  int t = 0,
}) => s.run<void>(null, (db) async {
  await db.customStatement(
    'INSERT INTO push_inbox(message_id, conversation_id, sender_id, body, '
    'sealed, received_at) VALUES (?, ?, ?, ?, ?, ?)',
    [id, conv, sender, body, 'ab' * 32, rx(t)],
  );
}, write: true);

Future<List<String>> inboxIds(DriftMessageStore s) async =>
    ids(await (s as PushInboxStore).pushInbox());

Future<int> userVersion(DriftMessageStore s) => s.run<int>(-1, (db) async {
  final r = await db.customSelect('PRAGMA user_version').getSingle();
  return r.read<int>('user_version');
});

Future<Set<String>> schemaNames(DriftMessageStore s, String type) =>
    s.run<Set<String>>({}, (db) async {
      final rows = await db
          .customSelect(
            'SELECT name FROM sqlite_master WHERE type = ?',
            variables: [Variable.withString(type)],
          )
          .get();
      return {for (final r in rows) r.read<String>('name')};
    });

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late StoreHarness h;
  late String key;
  late DriftMessageStore s;
  final opened = <DriftMessageStore>[];

  DriftMessageStore open() {
    final st = h.open(owner: 'bob', key: key);
    opened.add(st);
    return st;
  }

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    opened.clear();
    addTearDown(() async {
      for (final o in opened) {
        await o.close();
      }
    });
    s = open();
    await DriftChatListSnapshotStore(s).save('bob', const [
      Conversation(
        id: 'c1',
        other: Member(userId: 'alice', displayName: 'Alice'),
      ),
      Conversation(
        id: 'c2',
        other: Member(userId: 'carol', displayName: 'Carol'),
      ),
    ]);
  });

  group('schema 5', () {
    test(
      'a fresh store is version 5 with push_inbox and both triggers',
      () async {
        expect(await userVersion(s), 5);
        expect(await schemaNames(s, 'table'), contains('push_inbox'));
        expect(
          await schemaNames(s, 'trigger'),
          containsAll(['push_inbox_ai', 'push_inbox_au']),
        );
      },
    );

    test('a real v4 file with rows upgrades to 5: rows intact, push_inbox '
        'and both triggers exist and work', () async {
      await s.reconcilePage('c1', [
        msg('m1', t: 1, body: 'kahvaltı hazır', sender: 'alice'),
        msg('m2', t: 2, body: 'geliyorum', sender: 'bob'),
      ], reachedStart: true);
      await s.saveCursor(ChangeCursor(at(2), 'm2'));
      // Make it a real v4 file: schema 5's additions removed.
      await s.run<void>(null, (db) async {
        await db.customStatement('DROP TRIGGER push_inbox_ai');
        await db.customStatement('DROP TRIGGER push_inbox_au');
        await db.customStatement('DROP TABLE push_inbox');
        await db.customStatement('PRAGMA user_version = 4');
      }, write: true);
      expect(await schemaNames(s, 'table'), isNot(contains('push_inbox')));
      await s.close();

      final v5 = open();
      expect(await userVersion(v5), 5);
      expect(ids(await v5.newest('c1')), ['m1', 'm2'], reason: 'rows lost');
      expect(ids(await v5.search('kahvaltı')), ['m1'], reason: 'FTS lost');
      expect((await v5.cursor())?.id, 'm2', reason: 'meta lost');
      expect(
        (await DriftChatListSnapshotStore(v5).load('bob'))?.map((c) => c.id),
        ['c1', 'c2'],
        reason: 'conversations lost',
      );
      expect(await schemaNames(v5, 'table'), contains('push_inbox'));
      expect(
        await schemaNames(v5, 'trigger'),
        containsAll(['push_inbox_ai', 'push_inbox_au']),
      );
      // The tables work and the triggers fire.
      await putInbox(v5, 'n1', t: 1);
      await putInbox(v5, 'n2', t: 2);
      expect(await inboxIds(v5), ['n1', 'n2']);
      await v5.upsertAll([msg('n1', t: 3, sender: 'alice')]); // insert
      expect(await inboxIds(v5), ['n2']);
    });

    test('the 4 -> 5 step is re-runnable: user_version 4 over a file that '
        'already has push_inbox and its triggers opens, rows kept', () async {
      await s.upsertAll([msg('m1', t: 1)]);
      await putInbox(s, 'n1', t: 1);
      await s.run<void>(null, (db) async {
        await db.customStatement('PRAGMA user_version = 4');
      }, write: true);
      await s.close();

      final again = open();
      expect(await userVersion(again), 5);
      expect(ids(await again.newest('c1')), ['m1']);
      expect(await inboxIds(again), ['n1']);
    });

    test(
      'a real v1 file upgrades to 5 with push_inbox and the triggers',
      () async {
        await s.upsertAll([msg('m1', t: 1)]);
        await s.run<void>(null, (db) async {
          await db.customStatement('DROP TRIGGER push_inbox_ai');
          await db.customStatement('DROP TRIGGER push_inbox_au');
          await db.customStatement('DROP TABLE push_inbox');
          await db.customStatement('DROP TABLE read_marks');
          await db.customStatement('DROP TABLE olm_sessions');
          await db.customStatement('DROP TABLE send_queue');
          await db.customStatement('DROP TABLE reaction_plains');
          await db.customStatement('PRAGMA user_version = 1');
        }, write: true);
        await s.close();

        final v5 = open();
        expect(await userVersion(v5), 5);
        expect(ids(await v5.newest('c1')), ['m1']);
        expect(
          await schemaNames(v5, 'trigger'),
          containsAll(['push_inbox_ai', 'push_inbox_au']),
        );
        await putInbox(v5, 'n1');
        expect(await inboxIds(v5), ['n1']);
      },
    );
  });

  group('pushInbox()', () {
    test('every chat, oldest first, as Message with createdAt = received_at '
        'and the stored sender and body', () async {
      await putInbox(s, 'n3', conv: 'c2', sender: 'carol', body: 'third', t: 3);
      await putInbox(s, 'n1', body: 'first', t: 1);
      await putInbox(s, 'n2', body: 'second', t: 2);
      final rows = await (s as PushInboxStore).pushInbox();
      expect(ids(rows), ['n1', 'n2', 'n3']);
      final n3 = rows.last;
      expect(n3.conversationId, 'c2');
      expect(n3.senderId, 'carol');
      expect(n3.body, 'third');
      expect(
        n3.createdAt.microsecondsSinceEpoch,
        rx(3),
        reason: 'createdAt is received_at (microseconds)',
      );
    });

    test('inbox rows are not messages: newest() and search() never see '
        'them', () async {
      await putInbox(s, 'n1', body: 'gizli kelime');
      expect(await s.newest('c1'), isEmpty);
      expect(await s.search('gizli'), isEmpty);
    });

    test('an unreadable store gives an empty list, never throws', () async {
      await putInbox(s, 'n1');
      await s.close();
      final wrong = h.open(owner: 'bob', key: await h.newKey());
      opened.add(wrong);
      expect(await (wrong as PushInboxStore).pushInbox(), isEmpty);
    });
  });

  group('the app\'s own row replaces the inbox row (triggers)', () {
    setUp(() async {
      await putInbox(s, 'n1', t: 1);
      await putInbox(s, 'keep', t: 2);
    });

    test('insert of a readable row (upsertAll)', () async {
      await s.upsertAll([msg('n1', sender: 'alice', body: 'real text')]);
      expect(await inboxIds(s), ['keep']);
      expect((await s.newest('c1')).single.body, 'real text');
    });

    test('insert through reconcilePage', () async {
      await s.reconcilePage('c1', [
        msg('n1', sender: 'alice'),
      ], reachedStart: true);
      expect(await inboxIds(s), ['keep']);
    });

    test('upsert-update of an existing row', () async {
      await s.upsertAll([msg('n9', sender: 'alice', body: 'v1')]);
      // A row that exists before the inbox row lands (e.g. raw state), then
      // the server's edit updates it.
      await putInbox(s, 'n9', t: 3);
      expect(await inboxIds(s), ['n1', 'keep', 'n9']);
      await s.upsertAll([msg('n9', sender: 'alice', body: 'v2')]);
      expect(await inboxIds(s), ['n1', 'keep']);
    });

    for (final kind in MessageDeletion.values) {
      test('a deletion row ($kind)', () async {
        await s.upsertAll([msg('n1', body: '', deletion: kind)]);
        expect(await inboxIds(s), ['keep']);
      });
    }

    test('a lock placeholder (the app could not open it): the inbox row is '
        'deleted, the lock shows', () async {
      await s.upsertAll([
        msg('n1', sender: 'alice', body: lockedBodyPlaceholder),
      ]);
      expect(await inboxIds(s), ['keep']);
      expect((await s.newest('c1')).single.body, lockedBodyPlaceholder);
    });

    test('remove(id) of a vanished message deletes its inbox row; a cold '
        'open does not show the text', () async {
      await s.remove('n1');
      expect(await inboxIds(s), ['keep']);
      await s.close();
      expect(await inboxIds(open()), ['keep']);
    });

    test(
      'remove(id) after the vanished row was stored: no inbox row left',
      () async {
        await s.upsertAll([
          msg('n1', body: '', deletion: MessageDeletion.vanished),
        ]);
        await s.remove('n1');
        expect(await inboxIds(s), ['keep']);
        expect(await s.newest('c1'), isEmpty);
      },
    );

    test('extendOlder writing the row', () async {
      await s.reconcilePage('c1', [msg('m5', t: 5)], reachedStart: false);
      await s.extendOlder('c1', [
        msg('n1', t: 1, sender: 'alice'),
      ], reachedStart: true);
      expect(await inboxIds(s), ['keep']);
    });
  });

  group('sweepPushInbox(before)', () {
    test('deletes rows received before [before], keeps the rest', () async {
      await putInbox(s, 'old', t: 1);
      await putInbox(s, 'edge', t: 2);
      await putInbox(s, 'new', t: 3);
      await (s as PushInboxStore).sweepPushInbox(
        DateTime.fromMicrosecondsSinceEpoch(rx(2), isUtc: true),
      );
      expect(await inboxIds(s), ['edge', 'new'], reason: 'strictly before');
    });

    test('a local (JST) DateTime is the same instant', () async {
      await putInbox(s, 'old', t: 1);
      await putInbox(s, 'new', t: 3);
      await (s as PushInboxStore).sweepPushInbox(
        DateTime.fromMicrosecondsSinceEpoch(rx(2)), // local time
      );
      expect(await inboxIds(s), ['new']);
    });

    test('never throws on a closed store', () async {
      await s.close();
      await (s as PushInboxStore).sweepPushInbox(DateTime.now());
    });
  });

  group('cleanup', () {
    setUp(() async {
      await putInbox(s, 'a1', t: 1);
      await putInbox(s, 'b1', conv: 'c2', sender: 'carol', t: 2);
    });

    test('deleteConversation deletes that chat\'s inbox rows only', () async {
      await s.deleteConversation('c1');
      expect(await inboxIds(s), ['b1']);
    });

    test('the list save() dropping a chat deletes its inbox rows', () async {
      await DriftChatListSnapshotStore(s).save('bob', const [
        Conversation(
          id: 'c2',
          other: Member(userId: 'carol', displayName: 'Carol'),
        ),
      ]);
      expect(await inboxIds(s), ['b1']);
    });

    test('the list save() keeping every chat keeps the rows', () async {
      await DriftChatListSnapshotStore(s).save('bob', const [
        Conversation(
          id: 'c1',
          other: Member(userId: 'alice', displayName: 'Alice'),
        ),
        Conversation(
          id: 'c2',
          other: Member(userId: 'carol', displayName: 'Carol'),
        ),
      ]);
      expect(await inboxIds(s), ['a1', 'b1']);
    });

    test('the snapshot clear() deletes every inbox row', () async {
      await DriftChatListSnapshotStore(s).clear();
      expect(await inboxIds(s), isEmpty);
    });

    test('the store clear() (erase / sign-out) leaves no inbox row', () async {
      await s.clear();
      final again = open();
      expect(await inboxIds(again), isEmpty);
    });
  });

  group('held chat', () {
    Future<void> markHeld(DriftMessageStore st, String conv) =>
        DriftSecurityCodeStore(
          store: st,
          sessions: OlmKeyEngine(),
          pickleKey: _FixedPickleKey(),
        ).markHeld(conv, at(0));

    test('an inbox row in a held chat does not change its reconcile: the '
        'placeholder is kept, contiguousFrom stays, not complete', () async {
      await markHeld(s, 'c1');
      await putInbox(s, 'n9', body: 'push text', t: 9);
      await s.reconcilePage('c1', [
        msg('p1', t: 1, body: lockedBodyPlaceholder),
        for (var i = 2; i <= 5; i++) msg('m$i', t: i),
      ], reachedStart: false);
      await s.reconcilePage('c1', [
        msg('m4', t: 4),
        msg('m5', t: 5),
      ], reachedStart: true);
      expect(ids(await s.newest('c1')), ['p1', 'm4', 'm5']);
      final sync = (await s.syncState('c1'))!;
      expect(sync.contiguousFrom?.isAtSameMomentAs(at(1)), isTrue);
      expect(sync.complete, isFalse);
      expect(await inboxIds(s), ['n9'], reason: 'not in messages, kept');
    });
  });
}

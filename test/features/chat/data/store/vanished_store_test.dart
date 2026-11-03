// VanishedStore on a REAL encrypted DriftMessageStore, from the QA interface
// (never the code): markVanished leaves only an id-only tombstone
// (meta key vanished:<chat>:<id>, value ''); the message row and the
// push_inbox row are gone; vanishedIds is per chat; deleteConversation purges
// only its own chat's tombstones; clear removes all.
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/vanished_store.dart';

import 'store_harness.dart';

Future<int> _inbox(DriftMessageStore s, String id) =>
    s.run<int>(-1, (db) async {
      final r = await db
          .customSelect(
            'SELECT count(*) AS n FROM push_inbox WHERE message_id = ?',
            variables: [Variable.withString(id)],
          )
          .getSingle();
      return r.read<int>('n');
    });

Future<void> _putInbox(DriftMessageStore s, String id, String conv) =>
    s.run<void>(null, (db) async {
      await db.customStatement(
        'INSERT INTO push_inbox(message_id, conversation_id, sender_id, body, '
        'sealed, received_at) VALUES (?, ?, ?, ?, ?, ?)',
        [id, conv, 'alice', 'secret inbox words', 'ab' * 32, 1],
      );
    }, write: true);

Future<List<(String, String)>> _meta(DriftMessageStore s) =>
    s.run<List<(String, String)>>([], (db) async {
      final rows = await db
          .customSelect(
            "SELECT key, value FROM meta WHERE key LIKE 'vanished:%'",
          )
          .get();
      return [
        for (final r in rows) (r.read<String>('key'), r.read<String>('value')),
      ];
    });

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late StoreHarness h;
  late String key;
  late DriftMessageStore s;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    s = h.open(owner: 'bob', key: key);
    addTearDown(s.close);
  });

  VanishedStore v() => s;

  test('markVanished removes the message and inbox rows and writes only the '
      'id-only tombstone; nothing of the content is searchable', () async {
    await s.upsertAll([
      msg('m1', body: 'zebrafish meeting', sender: 'carol', t: 1),
      msg('m2', t: 2),
    ]);
    await _putInbox(s, 'm1', 'c1');
    await v().markVanished('m1', 'c1');

    expect(ids(await s.newest('c1')), ['m2']);
    expect(await _inbox(s, 'm1'), 0);
    expect(await _meta(s), [('vanished:c1:m1', '')]);
    expect(await s.search('zebrafish'), isEmpty);
    expect(await s.search('zebrafish', conversationId: 'c1'), isEmpty);
    expect(await v().vanishedIds('c1'), {'m1'});
  });

  test(
    'a repeat call is harmless; an unknown id still gets a tombstone',
    () async {
      await s.upsertAll([msg('m1', t: 1)]);
      await v().markVanished('m1', 'c1');
      await v().markVanished('m1', 'c1');
      await v().markVanished('never-stored', 'c1');
      expect(await v().vanishedIds('c1'), {'m1', 'never-stored'});
      expect(await _meta(s), hasLength(2));
    },
  );

  test('vanishedIds is per chat only', () async {
    await v().markVanished('a', 'c1');
    await v().markVanished('b', 'c2');
    await v().markVanished('c', 'c1');
    expect(await v().vanishedIds('c1'), {'a', 'c'});
    expect(await v().vanishedIds('c2'), {'b'});
    expect(await v().vanishedIds('c3'), isEmpty);
  });

  test('a chat id that is a prefix of another does not leak ids', () async {
    await v().markVanished('x', 'c1');
    await v().markVanished('y', 'c10');
    expect(await v().vanishedIds('c1'), {'x'});
    expect(await v().vanishedIds('c10'), {'y'});
  });

  test('empty when the store is closed or the owner is empty', () async {
    await v().markVanished('a', 'c1');
    await s.close();
    expect(await v().vanishedIds('c1'), isEmpty);
    final none = h.open(owner: '', key: key);
    addTearDown(none.close);
    expect(await none.vanishedIds('c1'), isEmpty);
  });

  test('deleteConversation purges only that chat tombstones', () async {
    await v().markVanished('a', 'c1');
    await v().markVanished('b', 'c2');
    await s.deleteConversation('c1');
    expect(await v().vanishedIds('c1'), isEmpty);
    expect(await v().vanishedIds('c2'), {'b'});
  });

  test('clear removes every tombstone', () async {
    await v().markVanished('a', 'c1');
    await v().markVanished('b', 'c2');
    await s.clear();
    expect(await _meta(s), isEmpty);
  });

  // Manager decision: a vanished id is final on the phone. All three insert
  // paths refuse a live row with a tombstoned id in the SAME chat only.
  group('a tombstoned id is never written again', () {
    Future<void> expectNothing(DriftMessageStore s) async {
      expect(ids(await s.newest('c1')).contains('m1'), isFalse);
      expect(ids(await s.older('c1', at(100))).contains('m1'), isFalse);
      expect(await s.search('zebrafish'), isEmpty);
      expect(await v().vanishedIds('c1'), {'m1'});
    }

    setUp(() async {
      await s.upsertAll([msg('keep', t: 50)]);
      await v().markVanished('m1', 'c1');
    });

    test('upsertAll', () async {
      await s.upsertAll([msg('m1', body: 'zebrafish', t: 1)]);
      await expectNothing(s);
    });

    test('reconcilePage', () async {
      await s.reconcilePage('c1', [
        msg('m1', body: 'zebrafish', t: 1),
        msg('keep', t: 50),
      ], reachedStart: true);
      await expectNothing(s);
      expect(ids(await s.newest('c1')), ['keep']);
    });

    test('extendOlder', () async {
      await s.reconcilePage('c1', [msg('keep', t: 50)], reachedStart: false);
      await s.extendOlder('c1', [
        msg('m1', body: 'zebrafish', t: 1),
        msg('m0', t: 2),
      ], reachedStart: true);
      await expectNothing(s);
      expect(ids(await s.newest('c1')), containsAll(['keep', 'm0']));
    });

    test('the same id in ANOTHER chat is still written', () async {
      await s.upsertAll([msg('m1', conv: 'c2', body: 'zebrafish', t: 1)]);
      expect(ids(await s.newest('c2')), ['m1']);
      expect(await s.search('zebrafish'), hasLength(1));
    });
  });
}

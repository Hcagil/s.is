// MessageStore.upsertAll rules (Private Chats 4a Group E), on the REAL
// encrypted DriftMessageStore, written from the contract, never from the
// implementation:
// - a stored deleted row is never replaced by a live one, also when the
//   live write races the deletion;
// - a deletion row always replaces what is stored;
// - a locked placeholder never replaces readable text;
// - a pending row is skipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';

import 'store_harness.dart';

void main() {
  late DriftMessageStore store;

  setUp(() async {
    final h = await StoreHarness.create();
    store = h.open(owner: 'u1', key: await h.newKey());
    addTearDown(store.close);
  });

  Future<Message?> row(String id) async => (await store.newest(
    'c1',
    limit: 500,
  )).where((m) => m.id == id).firstOrNull;

  for (final kind in MessageDeletion.values) {
    test('a stored ${kind.name} row is never replaced by a live one', () async {
      await store.upsertAll([msg('m1', body: '', deletion: kind)]);
      await store.upsertAll([msg('m1', body: 'resurrected')]);
      final m = await row('m1');
      expect(m?.isDeleted, isTrue);
      expect(m?.body, isNot('resurrected'));
    });

    test('a ${kind.name} row replaces readable text', () async {
      await store.upsertAll([msg('m1', body: 'readable')]);
      await store.upsertAll([msg('m1', body: '', deletion: kind)]);
      expect((await row('m1'))?.deletion, kind);
    });
  }

  test('a deletion replaces a locked placeholder too', () async {
    await store.upsertAll([msg('m1', body: lockedBodyPlaceholder)]);
    await store.upsertAll([
      msg('m1', body: '', deletion: MessageDeletion.placeholder),
    ]);
    expect((await row('m1'))?.isDeleted, isTrue);
  });

  test('a deletion replaces an earlier deletion of another kind', () async {
    await store.upsertAll([
      msg('m1', body: '', deletion: MessageDeletion.placeholder),
    ]);
    await store.upsertAll([
      msg('m1', body: '', deletion: MessageDeletion.vanished),
    ]);
    expect((await row('m1'))?.deletion, MessageDeletion.vanished);
  });

  for (final deletionFirst in [true, false]) {
    test(
      'a live write racing a deletion never wins '
      '(${deletionFirst ? 'deletion' : 'live write'} issued first)',
      () async {
        const n = 40;
        await store.upsertAll([
          for (var i = 0; i < n; i++) msg('r$i', t: i, body: 'old $i'),
        ]);
        Future<void> live(int i) =>
            store.upsertAll([msg('r$i', t: i, body: 'edit $i')]);
        Future<void> gone(int i) => store.upsertAll([
          msg('r$i', t: i, body: '', deletion: MessageDeletion.placeholder),
        ]);
        await Future.wait([
          for (var i = 0; i < n; i++)
            ...(deletionFirst ? [gone(i), live(i)] : [live(i), gone(i)]),
        ]);
        final stored = await store.newest('c1', limit: 500);
        expect(stored, hasLength(n));
        expect(
          [
            for (final m in stored)
              if (!m.isDeleted) m.id,
          ],
          isEmpty,
          reason: 'every row was deleted; a live write brought one back',
        );
      },
    );
  }

  test('one batch applies each rule per row', () async {
    await store.upsertAll([
      msg('readable', body: 'keep me'),
      msg('deleted', t: 1, body: '', deletion: MessageDeletion.placeholder),
      msg('pendingOver', t: 2, body: 'stored text'),
      msg('toDelete', t: 3, body: 'bye'),
    ]);
    await store.upsertAll([
      msg('readable', body: lockedBodyPlaceholder),
      msg('deleted', t: 1, body: 'live again'),
      msg('pendingOver', t: 2, body: 'still sending', sending: true),
      msg('toDelete', t: 3, body: '', deletion: MessageDeletion.vanished),
      msg('pendingNew', t: 4, sending: true),
      msg('fresh', t: 5, body: 'new'),
    ]);
    expect((await row('readable'))?.body, 'keep me');
    expect((await row('deleted'))?.isDeleted, isTrue);
    expect((await row('pendingOver'))?.body, 'stored text');
    expect((await row('pendingOver'))?.sending, isFalse);
    expect((await row('toDelete'))?.deletion, MessageDeletion.vanished);
    expect(await row('pendingNew'), isNull);
    expect((await row('fresh'))?.body, 'new');
  });

  group('extendOlder (background fill) keeps the same rule', () {
    setUp(() async {
      await store.reconcilePage('c1', [
        msg('newest', t: 100),
      ], reachedStart: false);
    });

    test('an older live row never replaces a stored deleted one', () async {
      await store.upsertAll([
        msg('m1', t: 5, body: '', deletion: MessageDeletion.placeholder),
      ]);
      await store.extendOlder('c1', [
        msg('m1', t: 5, body: 'resurrected'),
      ], reachedStart: false);
      expect((await row('m1'))?.isDeleted, isTrue);
    });

    test('an older deletion row replaces stored readable text', () async {
      await store.upsertAll([msg('m1', t: 5, body: 'readable')]);
      await store.extendOlder('c1', [
        msg('m1', t: 5, body: '', deletion: MessageDeletion.placeholder),
      ], reachedStart: false);
      expect((await row('m1'))?.isDeleted, isTrue);
    });
  });
}

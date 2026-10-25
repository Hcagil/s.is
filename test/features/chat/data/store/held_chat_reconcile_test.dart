// A held chat (it ever held a locked text) keeps its stored placeholders and
// its contiguous range on a short page; written from the MessageStore
// contract, never from the implementation. Real SQLite3 Multiple Ciphers
// database; run under TZ=JST-9 like CI.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
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

/// A locked row that could not be opened: body = the placeholder.
Message locked(String id, {String conv = 'c1', int t = 0}) =>
    msg(id, conv: conv, t: t, body: lockedBodyPlaceholder);

void main() {
  late DriftMessageStore s;

  setUp(() async {
    final h = await StoreHarness.create();
    s = h.open(owner: 'owner-1', key: await h.newKey());
    addTearDown(s.close);
  });

  Future<void> markHeld(String conv) => DriftSecurityCodeStore(
    store: s,
    sessions: OlmKeyEngine(),
    pickleKey: _FixedPickleKey(),
  ).markHeld(conv, at(0));

  bool same(DateTime? a, DateTime b) => a != null && a.isAtSameMomentAs(b);

  group('reconcilePage, held chat', () {
    test('stored placeholder: a short page keeps it, deletes other stale rows, '
        'contiguousFrom stays, not complete', () async {
      await s.reconcilePage('c1', [
        locked('p1', t: 1),
        for (var i = 2; i <= 5; i++) msg('m$i', t: i),
      ], reachedStart: false);
      await s.reconcilePage('c1', [
        msg('m4', t: 4),
        msg('m5', t: 5),
      ], reachedStart: true);
      expect(ids(await s.newest('c1')), ['p1', 'm4', 'm5']);
      final sync = (await s.syncState('c1'))!;
      expect(same(sync.contiguousFrom, at(1)), isTrue);
      expect(sync.complete, isFalse);
    });

    test('a placeholder in the page range but missing from a full page '
        'is kept', () async {
      // Placeholder inside the page time range but missing from the page.
      await s.reconcilePage('c1', [
        msg('m1', t: 1),
        locked('p2', t: 2),
        msg('m3', t: 3),
      ], reachedStart: false);
      await s.reconcilePage('c1', [
        msg('m1', t: 1),
        msg('m3', t: 3),
      ], reachedStart: false);
      expect(ids(await s.newest('c1')), ['m1', 'p2', 'm3']);
    });

    test(
      'placeholder in the page: contiguousFrom = min(old, page oldest)',
      () async {
        await s.reconcilePage('c1', [
          for (var i = 1; i <= 3; i++) msg('m$i', t: i),
        ], reachedStart: false);
        await s.reconcilePage('c1', [
          locked('p4', t: 4),
          msg('m5', t: 5),
        ], reachedStart: true);
        final sync = (await s.syncState('c1'))!;
        expect(same(sync.contiguousFrom, at(1)), isTrue);
        expect(sync.complete, isFalse);
        expect(ids(await s.newest('c1')), contains('p4'));
      },
    );

    test('no earlier sync state: contiguousFrom = page oldest', () async {
      await s.upsertAll([locked('p1', t: 1)]);
      await s.reconcilePage('c1', [
        msg('m3', t: 3),
        msg('m4', t: 4),
      ], reachedStart: true);
      final sync = (await s.syncState('c1'))!;
      expect(same(sync.contiguousFrom, at(3)), isTrue);
      expect(sync.complete, isFalse);
      expect(ids(await s.newest('c1')), ['p1', 'm3', 'm4']);
    });

    test(
      'an empty page with reachedStart keeps placeholders, never complete',
      () async {
        await s.reconcilePage('c1', [
          locked('p1', t: 1),
          msg('m2', t: 2),
        ], reachedStart: false);
        await s.reconcilePage('c1', const [], reachedStart: true);
        expect(ids(await s.newest('c1')), ['p1']);
        final sync = await s.syncState('c1');
        expect(sync?.complete ?? false, isFalse);
        expect(same(sync!.contiguousFrom, at(1)), isTrue);
      },
    );

    test(
      'held by the meta mark only: contiguousFrom stays, not complete',
      () async {
        await markHeld('c1');
        await s.reconcilePage('c1', [
          for (var i = 1; i <= 5; i++) msg('m$i', t: i),
        ], reachedStart: false);
        await s.reconcilePage('c1', [
          msg('m4', t: 4),
          msg('m5', t: 5),
        ], reachedStart: true);
        final sync = (await s.syncState('c1'))!;
        expect(same(sync.contiguousFrom, at(1)), isTrue);
        expect(sync.complete, isFalse);
      },
    );

    test(
      'held by the meta mark only: an empty page is never complete',
      () async {
        await markHeld('c1');
        await s.reconcilePage('c1', [msg('m1', t: 1)], reachedStart: false);
        await s.reconcilePage('c1', const [], reachedStart: true);
        expect((await s.syncState('c1'))?.complete ?? false, isFalse);
      },
    );
  });

  group('reconcilePage, plain chat (unchanged)', () {
    test(
      'a short page deletes stale rows, raises contiguousFrom, sets complete; '
      'another chat\'s held mark or placeholder does not hold it',
      () async {
        await markHeld('c2');
        await s.upsertAll([locked('x1', conv: 'c2', t: 1)]);
        await s.reconcilePage('c1', [
          for (var i = 1; i <= 5; i++) msg('m$i', t: i),
        ], reachedStart: false);
        await s.reconcilePage('c1', [
          msg('m4', t: 4),
          msg('m5', t: 5),
        ], reachedStart: true);
        expect(ids(await s.newest('c1')), ['m4', 'm5']);
        final sync = (await s.syncState('c1'))!;
        expect(same(sync.contiguousFrom, at(4)), isTrue);
        expect(sync.complete, isTrue);
        // The other chat is never touched.
        expect(ids(await s.newest('c2')), ['x1']);
      },
    );
  });

  group('extendOlder', () {
    test('a placeholder never overwrites a stored readable row; readable rows '
        'still write', () async {
      await s.reconcilePage('c1', [
        msg('m5', t: 5),
        msg('m6', t: 6),
      ], reachedStart: false);
      await s.upsertAll([
        msg('m3', t: 3, body: 'plain3'),
        msg('m4', t: 4, body: 'old4'),
      ]);
      await s.extendOlder('c1', [
        msg('m2', t: 2, body: 'new2'),
        locked('m3', t: 3),
        msg('m4', t: 4, body: 'new4'),
      ], reachedStart: false);
      final got = {for (final m in await s.newest('c1')) m.id: m.body};
      expect(got['m3'], 'plain3');
      expect(got['m4'], 'new4');
      expect(got['m2'], 'new2');
    });
  });
}

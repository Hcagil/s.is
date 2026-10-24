// DriftReactionStore over a REAL encrypted store file (StoreHarness), written
// from the ReactionStore contract (lib/features/chat/domain/reaction_store.dart),
// never from the implementation:
//  * emojiOf answers only the exact (messageId, userId, sealed);
//  * put replaces any older emoji of the same (messageId, userId);
//  * usageOf counts one user's [limit] newest saved reactions;
//  * reads never throw (null / empty), a closed store skips writes;
//  * the table survives a reopen, and a v3 file is upgraded to hold it.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_reaction_store.dart';

import 'store_harness.dart';

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

  DriftMessageStore open() {
    final s = h.open(owner: 'alice', key: key);
    opened.add(s);
    return s;
  }

  test('emojiOf answers only the exact (message, user, sealed)', () async {
    final s = DriftReactionStore(open());
    await s.put('m1', 'bob', 'h1', '🦊');
    expect(await s.emojiOf('m1', 'bob', 'h1'), '🦊');
    expect(await s.emojiOf('m1', 'bob', 'h2'), isNull, reason: 'other bytes');
    expect(await s.emojiOf('m1', 'cat', 'h1'), isNull, reason: 'other user');
    expect(await s.emojiOf('m2', 'bob', 'h1'), isNull, reason: 'other message');
  });

  test(
    'a newer put of the same (message, user) replaces the older one',
    () async {
      final s = DriftReactionStore(open());
      await s.put('m1', 'bob', 'h1', '🦊');
      await s.put('m1', 'cat', 'h9', '🐙');
      await s.put('m1', 'bob', 'h2', '🐝');
      expect(await s.emojiOf('m1', 'bob', 'h2'), '🐝');
      expect(await s.emojiOf('m1', 'bob', 'h1'), isNull, reason: 'replaced');
      expect(
        await s.emojiOf('m1', 'cat', 'h9'),
        '🐙',
        reason: 'other user kept',
      );
    },
  );

  test(
    'usageOf counts one user\'s newest saved reactions, up to limit',
    () async {
      final s = DriftReactionStore(open());
      await s.put('m1', 'alice', 'a1', '👍');
      await s.put('m2', 'alice', 'a2', '👍');
      await s.put('m3', 'alice', 'a3', '❤️');
      await s.put('m4', 'bob', 'b1', '😂');
      expect(await s.usageOf('alice'), {'👍': 2, '❤️': 1});
      expect(await s.usageOf('bob'), {'😂': 1});
      expect(await s.usageOf('alice', limit: 1), {'❤️': 1});
      // a replaced reaction counts once, as its newest emoji
      await s.put('m1', 'alice', 'a4', '❤️');
      expect(await s.usageOf('alice'), {'👍': 1, '❤️': 2});
    },
  );

  test(
    'saved reactions survive closing and reopening the encrypted file',
    () async {
      final first = open();
      await DriftReactionStore(first).put('m1', 'bob', 'h1', '🦊');
      await first.close();
      expect(await DriftReactionStore(open()).emojiOf('m1', 'bob', 'h1'), '🦊');
    },
  );

  test('a closed store: reads are null / empty, writes are skipped, '
      'nothing throws', () async {
    final store = open();
    final s = DriftReactionStore(store);
    await s.put('m1', 'bob', 'h1', '🦊');
    await store.close();
    expect(await s.emojiOf('m1', 'bob', 'h1'), isNull);
    expect(await s.usageOf('bob'), isEmpty);
    await s.put('m2', 'bob', 'h2', '🐝');
    expect(
      await DriftReactionStore(open()).emojiOf('m2', 'bob', 'h2'),
      isNull,
      reason: 'the write after close was skipped',
    );
  });

  test(
    'a v3 file (no reaction_plains) is upgraded and keeps its messages',
    () async {
      final v3 = open();
      await v3.reconcilePage('c1', [
        msg('m1', t: 1, body: 'hello'),
      ], reachedStart: true);
      await v3.run<void>(null, (db) async {
        await db.customStatement('DROP TABLE reaction_plains');
        await db.customStatement('PRAGMA user_version = 3');
      });
      await v3.close();

      final v4 = open();
      expect([for (final m in await v4.newest('c1')) m.id], ['m1']);
      final s = DriftReactionStore(v4);
      await s.put('m1', 'bob', 'h1', '🦊');
      expect(await s.emojiOf('m1', 'bob', 'h1'), '🦊');
    },
  );
}

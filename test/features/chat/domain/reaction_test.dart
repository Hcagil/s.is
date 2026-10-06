import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/read_marks.dart';

/// Helper to convert a [Reaction] to a record for easy comparison.
(String, String, String?) reactionRecord(Reaction r) =>
    (r.messageId, r.userId, r.emoji);

void main() {
  group('Reaction', () {
    test('fields are accessible and immutable', () {
      const r = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      expect(r.messageId, 'm1');
      expect(r.userId, 'u1');
      expect(r.emoji, '👍');
    });
  });

  group('applyReaction', () {
    test('adds a new reaction', () {
      final map = <String, List<Reaction>>{};
      final r = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final newMap = applyReaction(map, r);

      expect(map, isEmpty);
      expect(newMap, containsPair('m1', [r]));
      // Ensure new list is a new instance
      expect(identical(map['m1'], newMap['m1']), isFalse);
    });

    test('replaces existing reaction for same user/message', () {
      final r1 = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final r2 = Reaction(messageId: 'm1', userId: 'u1', emoji: '❤️');
      final map = {
        'm1': [r1],
      };
      final newMap = applyReaction(map, r2);

      expect(map['m1']!, contains(r1));
      expect(newMap['m1']!, contains(r2));
      expect(newMap['m1']!.length, 1);
    });

    test('removes reaction when emoji is null', () {
      final r1 = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final r2 = Reaction(messageId: 'm1', userId: 'u1', emoji: null);
      final map = {
        'm1': [r1],
      };
      final newMap = applyReaction(map, r2);

      expect(newMap.containsKey('m1'), isFalse);
    });

    test('removes message key when last reaction removed', () {
      final r1 = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final r2 = Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️');
      final r3 = Reaction(messageId: 'm1', userId: 'u1', emoji: null);
      final map = {
        'm1': [r1, r2],
      };
      final newMap = applyReaction(map, r3);

      expect(newMap['m1']!.length, 1);
      expect(newMap['m1']!.first, r2);
    });

    test('does not mutate input map or lists', () {
      final r1 = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final map = {
        'm1': [r1],
      };
      final newMap = applyReaction(map, r1);

      // Input map unchanged
      expect(map['m1']!.first, r1);
      // New map has a new list instance
      expect(identical(map['m1'], newMap['m1']), isFalse);
    });
  });

  group('groupReactions', () {
    test('groups by messageId and skips null emojis', () {
      final r1 = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final r2 = Reaction(messageId: 'm1', userId: 'u2', emoji: null);
      final r3 = Reaction(messageId: 'm2', userId: 'u1', emoji: '❤️');
      final grouped = groupReactions([r1, r2, r3]);

      expect(grouped.length, 2);
      expect(grouped['m1']!.length, 1);
      expect(grouped['m1']!.first, r1);
      expect(grouped['m2']!.first, r3);
    });

    test('last entry for same user/message wins', () {
      final r1 = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final r2 = Reaction(messageId: 'm1', userId: 'u1', emoji: '❤️');
      final grouped = groupReactions([r1, r2]);

      expect(grouped['m1']!.first, r2);
    });
  });

  group('reactionChips', () {
    test('creates one chip per distinct emoji, sorted by count desc', () {
      final reactions = [
        Reaction(messageId: 'm1', userId: 'u1', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u3', emoji: '❤️'),
      ];
      final chips = reactionChips(reactions, null);

      expect(chips.length, 2);
      expect(chips[0].emoji, '👍');
      expect(chips[0].count, 2);
      expect(chips[1].emoji, '❤️');
      expect(chips[1].count, 1);
    });

    test('ties keep order of first appearance', () {
      final reactions = [
        Reaction(messageId: 'm1', userId: 'u1', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️'),
        Reaction(messageId: 'm1', userId: 'u3', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u4', emoji: '❤️'),
      ];
      final chips = reactionChips(reactions, null);

      // Both have count 2, order should be 👍 then ❤️
      expect(chips[0].emoji, '👍');
      expect(chips[1].emoji, '❤️');
    });

    test('mine marks only the chip of the emoji me used', () {
      final reactions = [
        Reaction(messageId: 'm1', userId: 'u2', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'me', emoji: '❤️'),
        Reaction(messageId: 'm1', userId: 'u3', emoji: '👍'),
      ];
      final chips = reactionChips(reactions, 'me');
      expect(
        [for (final c in chips) (c.emoji, c.count, c.mine)],
        [('👍', 2, false), ('❤️', 1, true)],
      );
    });

    test('me null results in all mine false', () {
      final reactions = [
        Reaction(messageId: 'm1', userId: 'me', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '👍'),
      ];
      final chips = reactionChips(reactions, null);

      expect(chips.every((c) => c.mine), isFalse);
    });

    test('null-emoji reactions are not counted', () {
      final reactions = [
        Reaction(messageId: 'm1', userId: 'u1', emoji: null),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '👍'),
      ];
      final chips = reactionChips(reactions, null);

      expect(chips.length, 1);
      expect(chips.first.emoji, '👍');
    });
  });

  group('myReaction', () {
    test('returns emoji for me', () {
      final reactions = [
        Reaction(messageId: 'm1', userId: 'me', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️'),
      ];
      expect(myReaction(reactions, 'me'), '👍');
    });

    test('returns null if me did not react', () {
      final reactions = [Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️')];
      expect(myReaction(reactions, 'me'), isNull);
    });

    test('me null returns null', () {
      final reactions = [Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️')];
      expect(myReaction(reactions, null), isNull);
    });
  });

  group('barEmojis', () {
    test('returns default when used is empty', () {
      final result = barEmojis({});
      expect(result, defaultReactionEmojis);
    });

    test('orders by count desc, ties alphabetical', () {
      final used = {'👍': 5, '❤️': 5, '😂': 3, '😢': 3};
      final result = barEmojis(used);

      // Count 5 first, alphabetical between 👍 and ❤️: '❤️' < '👍' lexicographically
      expect(result[0], '❤️');
      expect(result[1], '👍');
      // Count 3 next, alphabetical between 😢 and 😂: '😂' < '😢'
      expect(result[2], '😂');
      expect(result[3], '😢');
    });

    test('tops up from defaultReactionEmojis without duplicates', () {
      final used = {'👍': 2, '❤️': 1};
      final result = barEmojis(used);

      // Should contain 👍, ❤️, then default emojis that are not already present
      expect(result.contains('👍'), isTrue);
      expect(result.contains('❤️'), isTrue);
      // defaultReactionEmojis order: first one not in used
      final firstDefault = defaultReactionEmojis.firstWhere(
        (e) => !used.containsKey(e),
      );
      expect(result[2], firstDefault);
      // No duplicates
      expect(result.toSet().length, result.length);
    });

    test('truncates to reactionBarSize', () {
      final used = {for (var i = 0; i < 12; i++) 'e$i': i};
      final result = barEmojis(used);
      expect(result.length, reactionBarSize);
    });
  });

  group('ReadMark', () {
    final sentAt = DateTime.utc(2023, 1, 1, 12, 0, 0);

    test('hasRead true when shares and readAt >= sentAt', () {
      final mark = ReadMark(
        userId: 'u1',
        shares: true,
        readAt: sentAt.add(const Duration(seconds: 1)),
        deliveredAt: null,
      );
      expect(mark.hasRead(sentAt), isTrue);
    });

    test('hasRead false when shares false', () {
      final mark = ReadMark(
        userId: 'u1',
        shares: false,
        readAt: sentAt,
        deliveredAt: null,
      );
      expect(mark.hasRead(sentAt), isFalse);
    });

    test('hasRead false when readAt null', () {
      final mark = ReadMark(
        userId: 'u1',
        shares: true,
        readAt: null,
        deliveredAt: null,
      );
      expect(mark.hasRead(sentAt), isFalse);
    });

    test('hasRead false when readAt before sentAt', () {
      final mark = ReadMark(
        userId: 'u1',
        shares: true,
        readAt: sentAt.subtract(const Duration(seconds: 1)),
        deliveredAt: null,
      );
      expect(mark.hasRead(sentAt), isFalse);
    });

    test('hasRead true when readAt equals sentAt', () {
      final mark = ReadMark(
        userId: 'u1',
        shares: true,
        readAt: sentAt,
        deliveredAt: null,
      );
      expect(mark.hasRead(sentAt), isTrue);
    });
  });

  group('readersOf', () {
    final sentAt = DateTime.utc(2023, 1, 1, 12, 0, 0);

    test('returns readers sorted by readAt ascending', () {
      final marks = [
        ReadMark(
          userId: 'u1',
          shares: true,
          readAt: sentAt.add(const Duration(seconds: 5)),
          deliveredAt: null,
        ),
        ReadMark(
          userId: 'u2',
          shares: true,
          readAt: sentAt.add(const Duration(seconds: 2)),
          deliveredAt: null,
        ),
        ReadMark(
          userId: 'u3',
          shares: true,
          readAt: sentAt.add(const Duration(seconds: 10)),
          deliveredAt: null,
        ),
      ];
      final result = readersOf(marks, sentAt);

      expect(result.map((m) => m.userId).toList(), ['u2', 'u1', 'u3']);
    });

    test('excludes shares=false and readAt before sentAt', () {
      final marks = [
        ReadMark(
          userId: 'u1',
          shares: false,
          readAt: sentAt.add(const Duration(seconds: 5)),
          deliveredAt: null,
        ),
        ReadMark(
          userId: 'u2',
          shares: true,
          readAt: sentAt.subtract(const Duration(seconds: 1)),
          deliveredAt: null,
        ),
        ReadMark(userId: 'u3', shares: true, readAt: sentAt, deliveredAt: null),
      ];
      final result = readersOf(marks, sentAt);

      expect(result.map((m) => m.userId).toList(), ['u3']);
    });

    test('input list is not mutated', () {
      final marks = [
        ReadMark(userId: 'u1', shares: true, readAt: sentAt, deliveredAt: null),
      ];
      final copy = List<ReadMark>.from(marks);
      readersOf(marks, sentAt);
      expect(marks, copy);
    });
  });

  group('contract details the draft missed', () {
    test('applyReaction never mutates the input map or its lists, and leaves '
        'other messages and other users alone', () {
      final mine = Reaction(messageId: 'm1', userId: 'u1', emoji: '👍');
      final bob = Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️');
      final other = Reaction(messageId: 'm2', userId: 'u1', emoji: '😂');
      final map = <String, List<Reaction>>{
        'm1': [mine, bob],
        'm2': [other],
      };
      final removed = applyReaction(
        map,
        const Reaction(messageId: 'm1', userId: 'u1', emoji: null),
      );
      final changed = applyReaction(
        map,
        const Reaction(messageId: 'm1', userId: 'u1', emoji: '🔥'),
      );
      expect(map.keys, ['m1', 'm2']);
      expect(map['m1']!.map(reactionRecord), [
        ('m1', 'u1', '👍'),
        ('m1', 'u2', '❤️'),
      ]);
      expect(removed['m1']!.map(reactionRecord), [('m1', 'u2', '❤️')]);
      expect(removed['m2']!.map(reactionRecord), [('m2', 'u1', '😂')]);
      expect(changed['m1']!.map(reactionRecord).toSet(), {
        ('m1', 'u1', '🔥'),
        ('m1', 'u2', '❤️'),
      });
    });

    test('reactionChips: equal counts keep first-appearance order, not '
        'string order either way', () {
      final chips = reactionChips(const [
        Reaction(messageId: 'm1', userId: 'u1', emoji: '😂'),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '❤️'),
        Reaction(messageId: 'm1', userId: 'u3', emoji: '👍'),
      ], null);
      expect(chips.map((c) => c.emoji), ['😂', '❤️', '👍']);
    });

    test('applyReaction: removing a reaction nobody had changes nothing', () {
      final map = <String, List<Reaction>>{};
      final next = applyReaction(
        map,
        const Reaction(messageId: 'm1', userId: 'u1', emoji: null),
      );
      expect(next, isEmpty);
    });

    test('groupReactions: a later null for the same user does not resurrect, '
        'and a user\'s last emoji wins per message', () {
      final grouped = groupReactions(const [
        Reaction(messageId: 'm1', userId: 'u1', emoji: '👍'),
        Reaction(messageId: 'm1', userId: 'u2', emoji: '😂'),
        Reaction(messageId: 'm1', userId: 'u1', emoji: '❤️'),
        Reaction(messageId: 'm3', userId: 'u1', emoji: null),
      ]);
      expect(grouped.keys, ['m1']);
      expect(grouped['m1']!.map(reactionRecord).toSet(), {
        ('m1', 'u1', '❤️'),
        ('m1', 'u2', '😂'),
      });
    });

    test('barEmojis: used first, then the defaults in their order, no '
        'duplicates, exactly reactionBarSize', () {
      final firstDefault = defaultReactionEmojis.first;
      expect(barEmojis({firstDefault: 1}), defaultReactionEmojis);
      expect(barEmojis({'🦄': 1}), [
        '🦄',
        ...defaultReactionEmojis.take(reactionBarSize - 1),
      ]);
      final last = defaultReactionEmojis.last;
      expect(barEmojis({'🦄': 1, last: 3}), [
        last,
        '🦄',
        ...defaultReactionEmojis.where((e) => e != last).take(8),
      ]);
    });

    test('barEmojis: past ten used, the ten most used win', () {
      final used = {
        for (var i = 0; i < 12; i++) 'e${i.toString().padLeft(2, '0')}': i,
      };
      expect(barEmojis(used), [
        for (var i = 11; i >= 2; i--) 'e${i.toString().padLeft(2, '0')}',
      ]);
    });

    test('the constants: ten defaults, distinct; a bar of ten', () {
      expect(defaultReactionEmojis, hasLength(10));
      expect(defaultReactionEmojis.toSet(), hasLength(10));
      expect(reactionBarSize, 10);
      expect(
        pickerReactionEmojis.toSet(),
        hasLength(pickerReactionEmojis.length),
      );
    });

    test('readersOf: earliest reader first, input order not changed', () {
      final sent = DateTime.utc(2026, 10, 6, 15);
      final late = ReadMark(
        userId: 'late',
        shares: true,
        readAt: sent.add(const Duration(hours: 9)),
      );
      final early = ReadMark(
        userId: 'early',
        shares: true,
        readAt: sent.add(const Duration(minutes: 1)),
      );
      final marks = [late, early];
      expect(readersOf(marks, sent).map((m) => m.userId), ['early', 'late']);
      expect(marks.map((m) => m.userId), ['late', 'early']);
    });
  });
}

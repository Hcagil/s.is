import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_models.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';

AdminItem card(String id, {int seq = 1}) => AdminItem(
  id: 'k:$id',
  kind: 'card',
  seq: seq,
  removed: false,
  fields: {'id': id},
);

void main() {
  group('AdminCard.fromFields', () {
    test('empty map', () {
      final card = AdminCard.fromFields({});
      expect(card.id, '');
      expect(card.type, 'rule');
      expect(card.state, 'active');
      expect(card.applies, null);
      expect(card.area, null);
      expect(card.when, isEmpty);
      expect(card.words, isEmpty);
      expect(card.oneLiner, '');
      expect(card.allows, null);
      expect(card.forbids, null);
    });

    test('full map', () {
      final card = AdminCard.fromFields({
        'id': 'C-1',
        'type': 'app',
        'state': 'proposed',
        'applies': 'M, L',
        'area': 'release',
        'when': ['lead', 'worker'],
        'one_liner': 'one two',
        'words': ['a', 'b'],
        'allows': 'x',
        'forbids': 'y',
      });
      expect(card.id, 'C-1');
      expect(card.type, 'app');
      expect(card.state, 'proposed');
      expect(card.applies, 'M, L');
      expect(card.area, 'release');
      expect(card.when, ['lead', 'worker']);
      expect(card.words, ['a', 'b']);
      expect(card.oneLiner, 'one two');
      expect(card.allows, 'x');
      expect(card.forbids, 'y');
    });

    test('unknown type and state', () {
      final card = AdminCard.fromFields({'type': 'other', 'state': 'other'});
      expect(card.type, 'rule');
      expect(card.state, 'active');
    });

    test('empty strings and non-strings', () {
      final card = AdminCard.fromFields({
        'id': 5,
        'applies': '',
        'area': 5,
        'one_liner': 5,
        'allows': '',
        'forbids': 5,
      });
      expect(card.id, '');
      expect(card.applies, null);
      expect(card.area, null);
      expect(card.oneLiner, '');
      expect(card.allows, null);
      expect(card.forbids, null);
    });

    test('when and words filtering', () {
      final card = AdminCard.fromFields({
        'when': ['a', 1, null, 'b'],
        'words': ['x', 2, 'y'],
      });
      expect(card.when, ['a', 'b']);
      expect(card.words, ['x', 'y']);
    });

    test('never throws', () {
      expect(
        () => AdminCard.fromFields({
          'id': 5,
          'type': 5,
          'state': 5,
          'applies': 5,
          'area': 5,
          'when': 5,
          'one_liner': 5,
          'words': 5,
          'allows': 5,
          'forbids': 5,
        }),
        returnsNormally,
      );
    });
  });

  group('AdminSnapshot.cards', () {
    test('sorted ids', () {
      final snapshot = AdminSnapshot.full(
        [card('B'), card('A'), card('C')],
        cursor: 0,
        truncated: false,
      );
      final ids = snapshot.cards.map((c) => c.id).toList();
      expect(ids, ['A', 'B', 'C']);
    });

    test('card with empty id is dropped', () {
      final snapshot = AdminSnapshot.full(
        [card(''), card('X')],
        cursor: 0,
        truncated: false,
      );
      expect(snapshot.cards.length, 1);
      expect(snapshot.cards.first.id, 'X');
    });

    test('removed card via delta', () {
      final base = AdminSnapshot.full(
        [card('A'), card('B')],
        cursor: 0,
        truncated: false,
      );
      final next = base.withDelta([
        AdminItem(
          id: 'k:A',
          kind: 'card',
          seq: 2,
          removed: true,
          fields: const {},
        ),
      ], 1);
      expect(next.cards.map((c) => c.id).toList(), ['B']);
      expect(base.cards.length, 2);
    });

    test('unknown kinds ignored', () {
      final snapshot = AdminSnapshot.full(
        [
          AdminItem(
            id: 'k:Q',
            kind: 'question',
            seq: 1,
            removed: false,
            fields: {'id': 'Q'},
          ),
          AdminItem(
            id: 'k:Z',
            kind: 'zzz',
            seq: 1,
            removed: false,
            fields: {'id': 'Z'},
          ),
        ],
        cursor: 0,
        truncated: false,
      );
      expect(snapshot.cards, isEmpty);
    });

    test('empty snapshot', () {
      expect(AdminSnapshot.empty.cards, isEmpty);
      final snapshot = AdminSnapshot.full(
        [
          AdminItem(
            id: 'k:Q',
            kind: 'question',
            seq: 1,
            removed: false,
            fields: {'id': 'Q'},
          ),
        ],
        cursor: 0,
        truncated: false,
      );
      expect(snapshot.cards, isEmpty);
    });
  });
}

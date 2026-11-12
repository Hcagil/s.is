import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_assembler.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot.dart';
import 'package:sis/features/admin_panels/domain/admin_link_phase.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

List<String> ids(AdminSnapshot s) => [
  for (final i in s.toJson()['items'] as List) (i as Map)['id'] as String,
];

void main() {
  group('parseDown', () {
    test('valid snapshot part', () {
      final jsonStr = '''
      {
        "t":"snapshot",
        "id":"S-1",
        "part":1,
        "parts":2,
        "cursor":5,
        "truncated":false,
        "items":[
          {"id":"I-1","kind":"question","seq":1,"removed":false,"fields":{"id":"Q-1","question":"q","answers":["a"]}}
        ]
      }
      ''';
      final result = parseDown(jsonStr);
      expect(result, isA<AdminSnapshotPart>());
      final part = result as AdminSnapshotPart;
      expect(part.id, 'S-1');
      expect(part.part, 1);
      expect(part.parts, 2);
      expect(part.cursor, 5);
      expect(part.truncated, false);
      expect(part.items.length, 1);
      expect(part.items.first.id, 'I-1');
    });

    test('valid delta', () {
      final jsonStr = '''
      {
        "t":"items",
        "cursor":10,
        "items":[
          {"id":"I-2","kind":"question","seq":2,"removed":false,"fields":{"id":"Q-2","question":"q2","answers":["b"]}}
        ]
      }
      ''';
      final result = parseDown(jsonStr);
      expect(result, isA<AdminDelta>());
      final delta = result as AdminDelta;
      expect(delta.cursor, 10);
      expect(delta.items.length, 1);
      expect(delta.items.first.id, 'I-2');
    });

    test('bad JSON returns null', () {
      expect(parseDown('{"'), null);
      expect(parseDown('[]'), null);
      expect(parseDown('{"t":"x"}'), null);
    });

    test('snapshot part with invalid part numbers returns null', () {
      final jsonStr = '''
      {
        "t":"snapshot",
        "id":"S-1",
        "part":3,
        "parts":2,
        "cursor":5,
        "truncated":false,
        "items":[]
      }
      ''';
      expect(parseDown(jsonStr), null);
    });

    test('snapshot part with part 0 returns null', () {
      final jsonStr = '''
      {
        "t":"snapshot",
        "id":"S-1",
        "part":0,
        "parts":1,
        "cursor":5,
        "truncated":false,
        "items":[]
      }
      ''';
      expect(parseDown(jsonStr), null);
    });

    test('snapshot part with empty id returns null', () {
      final jsonStr = '''
      {
        "t":"snapshot",
        "id":"",
        "part":1,
        "parts":1,
        "cursor":5,
        "truncated":false,
        "items":[]
      }
      ''';
      expect(parseDown(jsonStr), null);
    });

    test('items with missing id are skipped', () {
      final jsonStr = '''
      {
        "t":"items",
        "cursor":1,
        "items":[
          {"kind":"question","seq":1,"removed":false,"fields":{"id":"Q-1","question":"q","answers":["a"]}},
          {"id":"I-3","kind":"question","seq":2,"removed":false,"fields":{"id":"Q-3","question":"q3","answers":["c"]}}
        ]
      }
      ''';
      final result = parseDown(jsonStr) as AdminDelta;
      expect(result.items.length, 1);
      expect(result.items.first.id, 'I-3');
    });

    test('removed flag is read', () {
      final jsonStr = '''
      {
        "t":"items",
        "cursor":1,
        "items":[
          {"id":"I-4","kind":"question","seq":1,"removed":true,"fields":{"id":"Q-4","question":"q4","answers":["d"]}}
        ]
      }
      ''';
      final result = parseDown(jsonStr) as AdminDelta;
      expect(result.items.first.removed, true);
    });
  });

  group('AdminAssembler', () {
    test('parts arriving 2 then 1 complete on second', () {
      final assembler = AdminAssembler();
      final part2 = AdminSnapshotPart(
        id: 'S-1',
        part: 2,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      final part1 = AdminSnapshotPart(
        id: 'S-1',
        part: 1,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      expect(assembler.addPart(part2), null);
      final snapshot = assembler.addPart(part1);
      expect(snapshot, isNotNull);
      expect(snapshot!.cursor, 5);
    });

    test('new id after half-finished drops old', () {
      final assembler = AdminAssembler();
      final partA1 = AdminSnapshotPart(
        id: 'A',
        part: 1,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      final partB1 = AdminSnapshotPart(
        id: 'B',
        part: 1,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      final partA2 = AdminSnapshotPart(
        id: 'A',
        part: 2,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      final partB2 = AdminSnapshotPart(
        id: 'B',
        part: 2,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      assembler.addPart(partA1);
      assembler.addPart(partB1);
      expect(assembler.addPart(partA2), null);
      // B was dropped when A2 arrived (a new id drops what was collected)
      expect(assembler.addPart(partB2), null);
    });

    test('a new id keeps only the new snapshot items', () {
      final assembler = AdminAssembler();
      AdminItem item(String id) =>
          AdminItem(id: id, kind: 'question', seq: 1, removed: false, fields: {});
      AdminSnapshotPart part(String sid, int n, String itemId) => AdminSnapshotPart(
        id: sid,
        part: n,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [item(itemId)],
      );
      assembler.addPart(part('A', 1, 'old-1'));
      assembler.addPart(part('B', 1, 'new-1'));
      final snapshot = assembler.addPart(part('B', 2, 'new-2'));
      expect(snapshot, isNotNull);
      expect(ids(snapshot!).toSet(), {'new-1', 'new-2'});
    });

    test('one-part snapshot completes immediately', () {
      final assembler = AdminAssembler();
      final part = AdminSnapshotPart(
        id: 'S',
        part: 1,
        parts: 1,
        cursor: 10,
        truncated: false,
        items: [],
      );
      final snapshot = assembler.addPart(part);
      expect(snapshot, isNotNull);
      expect(snapshot!.cursor, 10);
    });

    test('truncated flag if any part truncated', () {
      final assembler = AdminAssembler();
      final part1 = AdminSnapshotPart(
        id: 'S',
        part: 1,
        parts: 2,
        cursor: 5,
        truncated: true,
        items: [],
      );
      final part2 = AdminSnapshotPart(
        id: 'S',
        part: 2,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      assembler.addPart(part1);
      final snapshot = assembler.addPart(part2);
      expect(snapshot, isNotNull);
      expect(snapshot!.truncated, true);
    });

    test('cursor from part 1 even if parts have different cursors', () {
      final assembler = AdminAssembler();
      final part1 = AdminSnapshotPart(
        id: 'S',
        part: 1,
        parts: 2,
        cursor: 10,
        truncated: false,
        items: [],
      );
      final part2 = AdminSnapshotPart(
        id: 'S',
        part: 2,
        parts: 2,
        cursor: 20,
        truncated: false,
        items: [],
      );
      assembler.addPart(part1);
      final snapshot = assembler.addPart(part2);
      expect(snapshot, isNotNull);
      expect(snapshot!.cursor, 10);
    });

    test('reset drops half-finished', () {
      final assembler = AdminAssembler();
      final part1 = AdminSnapshotPart(
        id: 'S',
        part: 1,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      assembler.addPart(part1);
      assembler.reset();
      final part2 = AdminSnapshotPart(
        id: 'S',
        part: 2,
        parts: 2,
        cursor: 5,
        truncated: false,
        items: [],
      );
      expect(assembler.addPart(part2), null);
    });

    test('after completion assembler is empty', () {
      final assembler = AdminAssembler();
      final part1 = AdminSnapshotPart(
        id: 'S',
        part: 1,
        parts: 1,
        cursor: 5,
        truncated: false,
        items: [],
      );
      final snapshot = assembler.addPart(part1);
      expect(snapshot, isNotNull);
      final part2 = AdminSnapshotPart(
        id: 'T',
        part: 1,
        parts: 1,
        cursor: 6,
        truncated: false,
        items: [],
      );
      final snapshot2 = assembler.addPart(part2);
      expect(snapshot2, isNotNull);
    });
  });

  group('AdminSnapshot', () {
    test('full ignores removed items', () {
      final items = [
        AdminItem(id: 'I-1', kind: 'question', seq: 1, removed: false, fields: {}),
        AdminItem(id: 'I-2', kind: 'question', seq: 2, removed: true, fields: {}),
      ];
      final snapshot = AdminSnapshot.full(items, cursor: 1, truncated: false);
      expect(ids(snapshot), ['I-1']);
    });

    test('withDelta adds, replaces, removes', () {
      final base = AdminSnapshot.full(
        [AdminItem(id: 'I-1', kind: 'question', seq: 1, removed: false, fields: {})],
        cursor: 1,
        truncated: false,
      );
      final deltaItems = [
        AdminItem(id: 'I-2', kind: 'question', seq: 2, removed: false, fields: {}),
        AdminItem(id: 'I-1', kind: 'question', seq: 3, removed: true, fields: {}),
      ];
      final newSnap = base.withDelta(deltaItems, 2);
      expect(ids(newSnap), ['I-2']);
      expect(newSnap.cursor, 2);
    });

    test('immutability of withDelta', () {
      final base = AdminSnapshot.full(
        [AdminItem(id: 'I-1', kind: 'question', seq: 1, removed: false, fields: {})],
        cursor: 1,
        truncated: false,
      );
      final deltaItems = [
        AdminItem(id: 'I-2', kind: 'question', seq: 2, removed: false, fields: {}),
      ];
      final newSnap = base.withDelta(deltaItems, 2);
      expect(ids(base), ['I-1']);
      expect(base.cursor, 1);
      expect(ids(newSnap).toSet(), {'I-1', 'I-2'});
    });

    test('toJson and tryFromJson round-trip', () {
      final items = [
        AdminItem(id: 'I-1', kind: 'question', seq: 1, removed: false, fields: {'id': 'Q-1'}),
      ];
      final snap = AdminSnapshot.full(items, cursor: 5, truncated: true);
      final json = snap.toJson();
      final round = AdminSnapshot.tryFromJson(json);
      expect(round, isNotNull);
      expect(round!.cursor, 5);
      expect(round.truncated, true);
      expect(ids(round), ['I-1']);
    });

    test('tryFromJson null cases', () {
      expect(AdminSnapshot.tryFromJson(null), null);
      expect(AdminSnapshot.tryFromJson('x'), null);
      expect(AdminSnapshot.tryFromJson({'items': []}), null);
      expect(AdminSnapshot.tryFromJson({'cursor': 1, 'items': 'x'}), null);
    });
  });

  group('AdminLinkPhase', () {
    test('ownKeyOnServer false -> unlinked', () {
      expect(
        linkPhase(
          ownKeyOnServer: false,
          computerKeyPresent: true,
          hasPin: true,
          pinMatches: true,
        ),
        AdminLinkPhase.unlinked,
      );
    });

    test('own key, no computer key -> waiting', () {
      expect(
        linkPhase(
          ownKeyOnServer: true,
          computerKeyPresent: false,
          hasPin: false,
          pinMatches: false,
        ),
        AdminLinkPhase.waiting,
      );
    });

    test('own key, computer key present, hasPin, pinMatches -> linked', () {
      expect(
        linkPhase(
          ownKeyOnServer: true,
          computerKeyPresent: true,
          hasPin: true,
          pinMatches: true,
        ),
        AdminLinkPhase.linked,
      );
    });

    test('own key, computer key present, hasPin, !pinMatches -> changed', () {
      expect(
        linkPhase(
          ownKeyOnServer: true,
          computerKeyPresent: true,
          hasPin: true,
          pinMatches: false,
        ),
        AdminLinkPhase.changed,
      );
    });

    test('own key, computer key present, !hasPin -> confirm', () {
      expect(
        linkPhase(
          ownKeyOnServer: true,
          computerKeyPresent: true,
          hasPin: false,
          pinMatches: false,
        ),
        AdminLinkPhase.confirm,
      );
    });

    test('own key, computer key absent, hasPin -> changed', () {
      expect(
        linkPhase(
          ownKeyOnServer: true,
          computerKeyPresent: false,
          hasPin: true,
          pinMatches: false,
        ),
        AdminLinkPhase.changed,
      );
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_dashboard.dart';
import 'package:sis/features/admin_panels/presentation/admin_work_colors.dart';

void main() {
  group('AdminWorkEntry.fromElement', () {
    test('full map with all keys', () {
      final entry = AdminWorkEntry.fromElement({
        'who': 'alice',
        'doing': 'coding',
        'id': '1',
        'parent': '0',
        'state': 'running',
        'depth': 2.0,
      });
      expect(entry.title, 'alice: coding');
      expect(entry.who, 'alice');
      expect(entry.id, '1');
      expect(entry.parent, '0');
      expect(entry.state, 'running');
      expect(entry.depth, 2);
    });

    test('missing keys default', () {
      final entry = AdminWorkEntry.fromElement({'doing': 'testing'});
      expect(entry.title, 'testing');
      expect(entry.who, '');
      expect(entry.id, null);
      expect(entry.parent, null);
      expect(entry.state, '');
      expect(entry.depth, 0);
    });

    test('who falls back to name', () {
      final entry = AdminWorkEntry.fromElement({
        'name': 'bob',
        'doing': 'review',
      });
      expect(entry.title, 'bob: review');
      expect(entry.who, 'bob');
    });

    test('empty id/parent become null', () {
      final entry = AdminWorkEntry.fromElement({
        'who': 'carl',
        'doing': 'deploy',
        'id': '',
        'parent': '',
      });
      expect(entry.id, null);
      expect(entry.parent, null);
    });

    test('legacy stale mapping', () {
      final entry = AdminWorkEntry.fromElement({
        'who': 'dave',
        'doing': 'monitor',
        'state': 'unknown',
        'stale': true,
      });
      expect(entry.state, 'stale');
    });

    test('known states are kept', () {
      for (final s in ['running', 'shell', 'stale']) {
        final entry = AdminWorkEntry.fromElement({
          'who': 'alpha',
          'doing': 'x',
          'state': s,
        });
        expect(entry.state, s);
      }
    });

    test('unknown state without stale', () {
      final entry = AdminWorkEntry.fromElement({
        'who': 'eve',
        'doing': 'audit',
        'state': 'unknown',
        'stale': false,
      });
      expect(entry.state, '');
    });

    test('depth from num', () {
      final entry = AdminWorkEntry.fromElement({
        'who': 'frank',
        'doing': 'plan',
        'depth': 3.7,
      });
      expect(entry.depth, 3);
    });

    test('non-map element', () {
      final entry = AdminWorkEntry.fromElement('abc');
      expect(entry.title, 'abc');
      expect(entry.who, '');
      expect(entry.id, null);
      expect(entry.parent, null);
      expect(entry.state, '');
      expect(entry.depth, 0);
    });

    test('non-map numeric element', () {
      final entry = AdminWorkEntry.fromElement(42);
      expect(entry.title, '42');
    });

    test('non-map null element', () {
      final entry = AdminWorkEntry.fromElement(null);
      expect(entry.title, 'null');
    });

    test('does not throw on wrong-typed values', () {
      expect(
        () => AdminWorkEntry.fromElement({'who': 5, 'depth': 'x'}),
        returnsNormally,
      );
    });
  });

  group('AdminDashboard.fromFields', () {
    test('working missing', () {
      final dash = AdminDashboard.fromFields({});
      expect(dash.working, isEmpty);
    });

    test('working not a list', () {
      final dash = AdminDashboard.fromFields({'working': 'oops'});
      expect(dash.working, isEmpty);
    });

    test('mixed working list', () {
      final dash = AdminDashboard.fromFields({
        'working': [
          {'who': 'a', 'doing': 'x'},
          'b',
          {'who': 'c', 'doing': 'y'},
        ],
      });
      expect(dash.working.length, 3);
    });
  });

  group('adminWorkDotColors', () {
    test('contains expected keys and values', () {
      expect(adminWorkDotColors.length, 3);
      expect(adminWorkDotColors['running'], const Color(0xFF108F25));
      expect(adminWorkDotColors['shell'], const Color(0xFF997711));
      expect(adminWorkDotColors['stale'], const Color(0xFFE83342));
      expect(adminWorkDotColors.containsKey(''), false);
    });
  });

  group('adminThreadColor', () {
    test('all 16 cells', () {
      final expected = [
        [0xFF197739, 0xFF1D8640, 0xFF209547, 0xFF22A14D],
        [0xFF2867BE, 0xFF3074D3, 0xFF4582D8, 0xFF578EDB],
        [0xFF9338D5, 0xFF9F4ED9, 0xFFA961DD, 0xFFB270E1],
        [0xFFBA2889, 0xFFD12C9A, 0xFFD849A8, 0xFFDD5EB2],
      ];
      for (var f = 0; f < 4; f++) {
        for (var d = 0; d < 4; d++) {
          final color = adminThreadColor(f, d + 1);
          expect(color.toARGB32(), expected[f][d]);
        }
      }
    });

    test('clamping and modulo', () {
      expect(adminThreadColor(4, 0).toARGB32(), 0xFF197739);
      expect(adminThreadColor(4, 1).toARGB32(), 0xFF197739);
      expect(adminThreadColor(4, 9).toARGB32(), 0xFF22A14D);
    });
  });

  group('adminWorkFamilies', () {
    test('two roots with children', () {
      final entries = [
        AdminWorkEntry.fromElement({'id': '1', 'who': 'alpha', 'doing': 'a'}),
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': '1',
        }),
        AdminWorkEntry.fromElement({'id': '3', 'who': 'gamma', 'doing': 'c'}),
        AdminWorkEntry.fromElement({
          'id': '4',
          'who': 'delta',
          'doing': 'd',
          'parent': '3',
        }),
      ];
      expect(adminWorkFamilies(entries), [0, 0, 1, 1]);
    });

    test('child before root', () {
      final entries = [
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': '1',
        }),
        AdminWorkEntry.fromElement({'id': '1', 'who': 'alpha', 'doing': 'a'}),
      ];
      expect(adminWorkFamilies(entries), [0, 0]);
    });

    test('parent loop terminates', () {
      final entries = [
        AdminWorkEntry.fromElement({
          'id': 'a',
          'who': 'x',
          'doing': 'x',
          'parent': 'b',
        }),
        AdminWorkEntry.fromElement({
          'id': 'b',
          'who': 'y',
          'doing': 'y',
          'parent': 'a',
        }),
      ];
      final fams = adminWorkFamilies(entries);
      expect(fams.length, 2);
      expect(fams.every((f) => f >= 0 && f <= 1), isTrue);
    });

    test('unknown parent becomes own root', () {
      final entries = [
        AdminWorkEntry.fromElement({'id': '1', 'who': 'alpha', 'doing': 'a'}),
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': 'zzz',
        }),
      ];
      expect(adminWorkFamilies(entries), [0, 1]);
    });
  });

  group('adminCallerName', () {
    test('found caller', () {
      final entries = [
        AdminWorkEntry.fromElement({'id': '1', 'who': 'alpha', 'doing': 'a'}),
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': '1',
        }),
      ];
      expect(adminCallerName(entries[1], entries), 'alpha');
    });

    test('unknown caller', () {
      final entries = [
        AdminWorkEntry.fromElement({'id': '1', 'who': 'alpha', 'doing': 'a'}),
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': 'zzz',
        }),
      ];
      expect(adminCallerName(entries[1], entries), null);
    });

    test('null parent', () {
      final entries = [
        AdminWorkEntry.fromElement({'id': '1', 'who': 'alpha', 'doing': 'a'}),
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': null,
        }),
      ];
      expect(adminCallerName(entries[1], entries), null);
    });

    test('empty who', () {
      final entries = [
        AdminWorkEntry.fromElement({'id': '1', 'who': '', 'doing': 'a'}),
        AdminWorkEntry.fromElement({
          'id': '2',
          'who': 'beta',
          'doing': 'b',
          'parent': '1',
        }),
      ];
      expect(adminCallerName(entries[1], entries), null);
    });
  });
}

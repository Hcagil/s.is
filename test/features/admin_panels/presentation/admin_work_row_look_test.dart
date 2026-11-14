import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/domain/admin_dashboard.dart';
import 'package:sis/features/admin_panels/presentation/admin_work_colors.dart';
import 'package:sis/features/admin_panels/presentation/admin_work_row.dart';
import 'package:sis/l10n/app_localizations.dart';

Future<void> pumpRows(
  WidgetTester tester,
  List<AdminWorkEntry> entries, {
  List<int>? families,
}) async {
  final fam = families ?? adminWorkFamilies(entries);
  await tester.pumpWidget(
    MaterialApp(
      theme: sisTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            for (var i = 0; i < entries.length; i++)
              AdminWorkRow(entry: entries[i], entries: entries, family: fam[i]),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color? dotColor(WidgetTester tester, String id) =>
    ((tester.widget<Container>(find.byKey(ValueKey('admin-work-dot-$id'))))
                .decoration
            as BoxDecoration)
        .color;

Color lineColor(WidgetTester tester, String id) => tester
    .widget<ColoredBox>(find.byKey(ValueKey('admin-work-line-$id')))
    .color;

void main() {
  group('AdminWorkRow dot colors', () {
    final states = {
      'running': const Color(0xFF108F25),
      'shell': const Color(0xFF997711),
      'stale': const Color(0xFFE83342),
    };

    states.forEach((state, expectedColor) {
      testWidgets('dot color for state "$state"', (WidgetTester tester) async {
        final entries = [
          AdminWorkEntry(title: 'alpha: work', id: 'a', state: state),
          AdminWorkEntry(title: 'beta: work', id: 'b', state: state),
        ];
        await pumpRows(tester, entries);
        expect(dotColor(tester, 'a'), equals(expectedColor));
        expect(dotColor(tester, 'b'), equals(expectedColor));
      });
    });

    testWidgets('dot color for empty and unknown state', (
      WidgetTester tester,
    ) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a', state: ''),
        AdminWorkEntry(title: 'beta: work', id: 'b', state: 'weird'),
      ];
      await pumpRows(tester, entries);
      final colorA = dotColor(tester, 'a');
      final colorB = dotColor(tester, 'b');
      expect(colorA, equals(colorB));
      expect(colorA, isNot(equals(const Color(0xFF108F25))));
      expect(colorA, isNot(equals(const Color(0xFF997711))));
      expect(colorA, isNot(equals(const Color(0xFFE83342))));
    });

    testWidgets('unknown state dot is the theme muted grey', (
      WidgetTester tester,
    ) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a', state: ''),
      ];
      await pumpRows(tester, entries);
      final ctx = tester.element(
        find.byKey(const ValueKey('admin-work-dot-a')),
      );
      expect(dotColor(tester, 'a'), SisBrand.of(ctx).muted);
    });
  });

  group('AdminWorkRow line presence', () {
    testWidgets('root has no line, child has line', (
      WidgetTester tester,
    ) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a'),
        AdminWorkEntry(title: 'beta: work', id: 'b', parent: 'a', depth: 1),
      ];
      await pumpRows(tester, entries);
      expect(find.byKey(ValueKey('admin-work-line-a')), findsNothing);
      expect(find.byKey(ValueKey('admin-work-line-b')), findsOneWidget);
    });
  });

  group('AdminWorkRow line colors', () {
    testWidgets('family 0 shades', (WidgetTester tester) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a'),
        AdminWorkEntry(title: 'beta: work', id: 'b', parent: 'a', depth: 1),
        AdminWorkEntry(title: 'gamma: work', id: 'c', parent: 'a', depth: 3),
        AdminWorkEntry(title: 'delta: work', id: 'd', parent: 'a', depth: 9),
      ];
      await pumpRows(tester, entries, families: [0, 0, 0, 0]);
      expect(lineColor(tester, 'b'), equals(const Color(0xFF197739)));
      expect(lineColor(tester, 'c'), equals(const Color(0xFF209547)));
      expect(lineColor(tester, 'd'), equals(const Color(0xFF22A14D)));
    });

    testWidgets('family 1,2,3 shades', (WidgetTester tester) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a'),
        AdminWorkEntry(title: 'beta: work', id: 'b', parent: 'a', depth: 1),
      ];

      await pumpRows(tester, entries, families: [1, 1]);
      expect(lineColor(tester, 'b'), equals(const Color(0xFF2867BE)));

      await pumpRows(tester, entries, families: [2, 2]);
      expect(lineColor(tester, 'b'), equals(const Color(0xFF9338D5)));

      await pumpRows(tester, entries, families: [3, 3]);
      expect(lineColor(tester, 'b'), equals(const Color(0xFFBA2889)));
    });

    testWidgets('families from helper', (WidgetTester tester) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a'),
        AdminWorkEntry(title: 'beta: work', id: 'b', parent: 'a', depth: 1),
        AdminWorkEntry(title: 'x: work', id: 'x'),
        AdminWorkEntry(title: 'y: work', id: 'y', parent: 'x', depth: 1),
      ];
      await pumpRows(tester, entries);
      expect(lineColor(tester, 'b'), equals(const Color(0xFF197739)));
      expect(lineColor(tester, 'y'), equals(const Color(0xFF2867BE)));
    });
  });

  group('AdminWorkRow indentation', () {
    testWidgets('no indentation for chain', (WidgetTester tester) async {
      final entries = [
        AdminWorkEntry(title: 'alpha: work', id: 'a'),
        AdminWorkEntry(title: 'beta: work', id: 'b', parent: 'a', depth: 1),
        AdminWorkEntry(title: 'gamma: work', id: 'c', parent: 'b', depth: 2),
      ];
      await pumpRows(tester, entries);
      final dotA = tester
          .getTopLeft(find.byKey(ValueKey('admin-work-dot-a')))
          .dx;
      final dotB = tester
          .getTopLeft(find.byKey(ValueKey('admin-work-dot-b')))
          .dx;
      final dotC = tester
          .getTopLeft(find.byKey(ValueKey('admin-work-dot-c')))
          .dx;
      expect(dotA, equals(dotB));
      expect(dotB, equals(dotC));

      final titleA = tester.getTopLeft(find.text('alpha: work')).dx;
      final titleB = tester.getTopLeft(find.text('beta: work')).dx;
      final titleC = tester.getTopLeft(find.text('gamma: work')).dx;
      expect(titleA, equals(titleB));
      expect(titleB, equals(titleC));

      final lineB = tester
          .getTopLeft(find.byKey(ValueKey('admin-work-line-b')))
          .dx;
      final lineC = tester
          .getTopLeft(find.byKey(ValueKey('admin-work-line-c')))
          .dx;
      expect(lineB, equals(lineC));

      final lineWidth = tester
          .getSize(find.byKey(ValueKey('admin-work-line-b')))
          .width;
      expect(lineWidth, equals(3.0));
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/domain/admin_dashboard.dart';
import 'package:sis/features/admin_panels/presentation/admin_work_colors.dart';
import 'package:sis/features/admin_panels/presentation/admin_work_row.dart';
import 'package:sis/l10n/app_localizations.dart';

Future<void> pumpRows(
  WidgetTester tester,
  List<AdminWorkEntry> entries,
  Locale locale,
) async {
  final fam = adminWorkFamilies(entries);
  await tester.pumpWidget(
    MaterialApp(
      theme: sisTheme(Brightness.light),
      locale: locale,
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

Semantics rowSem(WidgetTester tester, String id) {
  final dotFinder = find.byKey(ValueKey('admin-work-dot-$id'));
  final semFinder = find.ancestor(
    of: dotFinder,
    matching: find.byType(Semantics),
  );
  final sem = tester.widget<Semantics>(semFinder.first);
  return sem;
}

void main() {
  const alpha = 'alpha';
  const beta = 'beta';
  const aId = 'a';
  const bId = 'b';

  final alphaEntry = AdminWorkEntry(title: 'alpha: work', who: alpha, id: aId);
  final betaEntry = AdminWorkEntry(
    title: 'beta: work',
    who: beta,
    id: bId,
    parent: aId,
    state: 'running',
    depth: 1,
  );

  group('AdminWorkRow semantics', () {
    testWidgets('EN single entry, various states', (tester) async {
      final states = [
        ['running', 'adminDashWorkStateRunning'],
        ['shell', 'adminDashWorkStateShell'],
        ['stale', 'adminDashWorkStateStale'],
        ['', 'adminDashWorkStateUnknown'],
      ];
      for (final pair in states) {
        final state = pair[0];
        final entry = AdminWorkEntry(
          title: 'alpha: work',
          who: alpha,
          id: aId,
          state: state,
        );
        await pumpRows(tester, [entry], const Locale('en'));
        final l = lookupAppLocalizations(const Locale('en'));
        final stateWord = switch (state) {
          'running' => l.adminDashWorkStateRunning,
          'shell' => l.adminDashWorkStateShell,
          'stale' => l.adminDashWorkStateStale,
          _ => l.adminDashWorkStateUnknown,
        };
        final actualLabel = rowSem(tester, aId).properties.label;
        expect(actualLabel, '${entry.title}, $stateWord');
      }
    });

    testWidgets('EN with caller', (tester) async {
      await pumpRows(tester, [alphaEntry, betaEntry], const Locale('en'));
      final l = lookupAppLocalizations(const Locale('en'));
      final callerLabel = l.adminDashWorkCalledBy(
        l.adminDashWorkStateRunning,
        alpha,
      );
      final childLabel = '${betaEntry.title}, $callerLabel';
      final parentLabel = '${alphaEntry.title}, ${l.adminDashWorkStateUnknown}';
      expect(rowSem(tester, bId).properties.label, childLabel);
      expect(rowSem(tester, aId).properties.label, parentLabel);
    });

    testWidgets('EN unknown parent', (tester) async {
      final unknownParentEntry = AdminWorkEntry(
        title: 'beta: work',
        who: beta,
        id: bId,
        parent: 'zzz',
        state: 'running',
        depth: 1,
      );
      await pumpRows(tester, [
        alphaEntry,
        unknownParentEntry,
      ], const Locale('en'));
      final l = lookupAppLocalizations(const Locale('en'));
      final expectedLabel =
          '${unknownParentEntry.title}, ${l.adminDashWorkStateRunning}';
      expect(rowSem(tester, bId).properties.label, expectedLabel);
      expect(find.byKey(ValueKey('admin-work-line-b')), findsOneWidget);
    });

    testWidgets('TR with caller and unknown parent', (tester) async {
      await pumpRows(tester, [alphaEntry, betaEntry], const Locale('tr'));
      final l = lookupAppLocalizations(const Locale('tr'));
      final callerLabel = l.adminDashWorkCalledBy(
        l.adminDashWorkStateRunning,
        alpha,
      );
      final childLabel = '${betaEntry.title}, $callerLabel';
      final parentLabel = '${alphaEntry.title}, ${l.adminDashWorkStateUnknown}';
      expect(rowSem(tester, bId).properties.label, childLabel);
      expect(rowSem(tester, aId).properties.label, parentLabel);

      final unknownParentEntry = AdminWorkEntry(
        title: 'beta: work',
        who: beta,
        id: bId,
        parent: 'zzz',
        state: 'running',
        depth: 1,
      );
      await pumpRows(tester, [
        alphaEntry,
        unknownParentEntry,
      ], const Locale('tr'));
      final trLabel =
          '${unknownParentEntry.title}, ${l.adminDashWorkStateRunning}';
      expect(rowSem(tester, bId).properties.label, trLabel);
      expect(find.byKey(ValueKey('admin-work-line-b')), findsOneWidget);

      // Ensure TR no-caller label differs from EN
      await pumpRows(tester, [alphaEntry], const Locale('en'));
      final enLabel = rowSem(tester, aId).properties.label;
      await pumpRows(tester, [alphaEntry], const Locale('tr'));
      final trNoCallerLabel = rowSem(tester, aId).properties.label;
      expect(enLabel, isNot(trNoCallerLabel));
      final trExpectedLabel =
          '${alphaEntry.title}, ${lookupAppLocalizations(const Locale('tr')).adminDashWorkStateUnknown}';
      expect(trNoCallerLabel, trExpectedLabel);
    });

    testWidgets('excludeSemantics true', (tester) async {
      await pumpRows(tester, [alphaEntry], const Locale('en'));
      expect(rowSem(tester, aId).excludeSemantics, isTrue);
      await pumpRows(tester, [betaEntry], const Locale('en'));
      expect(rowSem(tester, bId).excludeSemantics, isTrue);
    });
  });
}

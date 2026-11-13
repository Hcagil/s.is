import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/app/settings_row.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_dashboard_view.dart';
import 'package:sis/l10n/app_localizations.dart';

/// Helper to build the widget under test inside a MaterialApp with the
/// required providers and theme.  The optional [size] can be used to
/// override the logical size of the view for tests that need a specific
/// screen size.
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: const AdminDashboardView()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late ProviderContainer container;
  late FakeAdminRepository repo;

  setUp(() {
    repo = FakeAdminRepository();
    container = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
        adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
      ],
    );
  });

  tearDown(() => container.dispose());

  /// Helper to prepare a dashboard snapshot with the given fields.
  Future<void> prepareDashboard(Map<String, Object?> fields) async {
    final dash = AdminItem(
      id: 'dashboard',
      kind: 'dashboard',
      seq: 1,
      removed: false,
      fields: fields,
    );
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [dash]),
      ],
    ];
    // keep provider alive
    container.listen(adminPanelsProvider, (_, _) {});
    await container.read(adminPanelsProvider.notifier).open('r');
    await container.read(adminPanelsProvider.notifier).refresh();
    expect(container.read(adminPanelsProvider).hasSnapshot, isTrue);
  }

  testWidgets('running-now, context-size and tasks-left rows show no arrow', (
    tester,
  ) async {
    await prepareDashboard({
      'working': [
        {
          'kind': 'session',
          'who': 'Session A',
          'doing': 'Editing a file',
          'model': 'model-x',
          'secs': 30,
          'project': 'proj',
        },
      ],
      'sessions': [
        {
          'name': 'Session B',
          'ctx': 120,
          'counts': {'running': 2, 'pending': 3},
          'rows': [],
          'todo': [],
        },
      ],
      'stale': false,
    });

    await _pump(tester, container);

    // Verify the three sections exist
    final workRowFinder = find.byKey(const ValueKey('admin-dash-work-0'));
    final ctxRowFinder = find.byKey(const ValueKey('admin-dash-ctx-Session B'));
    final tasksLeftFinder = find.ancestor(
      of: find.byIcon(Icons.checklist_rounded),
      matching: find.byType(SisSettingsRow),
    );

    expect(workRowFinder, findsOneWidget);
    expect(ctxRowFinder, findsOneWidget);
    expect(tasksLeftFinder, findsOneWidget);

    // Verify no chevron_right icon in any of the rows
    void noArrow(Finder rowFinder, String section) {
      expect(
        find.descendant(
          of: rowFinder,
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
        reason: 'Arrow found in $section row',
      );
    }

    noArrow(workRowFinder, 'running-now');
    noArrow(ctxRowFinder, 'context-size');
    noArrow(tasksLeftFinder, 'tasks-left');
  });
}

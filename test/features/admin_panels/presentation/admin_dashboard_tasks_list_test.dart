import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

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

  // Fixture
  Map<String, Object?> dash() => {
    'working': [],
    'stale': false,
    'sessions': [
      {
        'name': 'Session Alpha',
        'ctx': 80,
        'counts': {'running': 1, 'review': 1, 'blocked': 1},
        'rows': [
          {'state': 'running', 'goal': 'Goal running one'},
          {'state': 'review', 'goal': 'Goal review two'},
          {'state': 'blocked', 'goal': 'Goal blocked three'},
        ],
        'todo': [
          {
            'list': 'List One',
            'open': ['item a', 'item b'],
          },
        ],
      },
    ],
  };

  const goals = ['Goal running one', 'Goal review two', 'Goal blocked three'];

  Finder buttons() => find.byWidgetPredicate(
    (w) =>
        w is ButtonStyleButton ||
        w is IconButton ||
        w is InkWell ||
        w is Checkbox ||
        w is Switch,
  );

  testWidgets('tasks-left list is closed at first', (tester) async {
    await prepareDashboard(dash());
    await _pump(tester, container);
    for (final g in goals) {
      expect(find.textContaining(g), findsNothing);
    }
    expect(find.textContaining('item a'), findsNothing);
  });

  testWidgets('tapping a session in tasks-left opens its task list', (
    tester,
  ) async {
    await prepareDashboard(dash());
    await _pump(tester, container);
    await tester.tap(
      find.byKey(const ValueKey('admin-dash-tasks-Session Alpha')),
    );
    await tester.pumpAndSettle();
    for (final g in goals) {
      expect(find.textContaining(g), findsOneWidget);
    }
    expect(find.textContaining('List One'), findsOneWidget);
    expect(find.textContaining('item a'), findsOneWidget);
    expect(find.textContaining('item b'), findsOneWidget);
  });

  testWidgets('the opened list is read-only: nothing in it can be tapped', (
    tester,
  ) async {
    await prepareDashboard(dash());
    await _pump(tester, container);
    final before = buttons().evaluate().length;
    await tester.tap(
      find.byKey(const ValueKey('admin-dash-tasks-Session Alpha')),
    );
    await tester.pumpAndSettle();
    expect(buttons().evaluate().length, before);
    for (final g in goals) {
      expect(
        find.ancestor(of: find.textContaining(g), matching: buttons()),
        findsNothing,
      );
    }
    await tester.tap(
      find.textContaining('Goal review two'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(repo.sent, isEmpty);
    expect(find.textContaining('Goal review two'), findsOneWidget);
  });
  Map<String, Object?> dashMany() => {
    'working': [],
    'stale': false,
    'sessions': [
      {
        'name': 'Session Beta',
        'ctx': 50,
        'counts': {'running': 3, 'review': 2, 'blocked': 1, 'pending': 2},
        'rows': [
          {'state': 'running', 'goal': 'Live goal 1'},
          {'state': 'running', 'goal': 'Live goal 2'},
          {'state': 'running', 'goal': 'Live goal 3'},
          {'state': 'review', 'goal': 'Live goal 4'},
          {'state': 'review', 'goal': 'Live goal 5'},
          {'state': 'blocked', 'goal': 'Live goal 6'},
          {'state': 'pending', 'goal': 'Waiting goal 1'},
          {'state': 'pending', 'goal': 'Waiting goal 2'},
        ],
        'todo': [
          {
            'list': 'List Two',
            'open': [
              'todo item 1',
              'todo item 2',
              'todo item 3',
              'todo item 4',
              'todo item 5',
            ],
          },
        ],
      },
    ],
  };

  testWidgets(
    'the opened list shows every task the computer sent, waiting ones too',
    (tester) async {
      await prepareDashboard(dashMany());
      await _pump(tester, container, size: const Size(800, 4000));
      await tester.tap(
        find.byKey(const ValueKey('admin-dash-tasks-Session Beta')),
      );
      await tester.pumpAndSettle();
      for (var i = 1; i <= 6; i++) {
        expect(find.textContaining('Live goal $i'), findsOneWidget);
      }
      for (var i = 1; i <= 2; i++) {
        expect(find.textContaining('Waiting goal $i'), findsOneWidget);
      }
      for (var i = 1; i <= 5; i++) {
        expect(find.textContaining('todo item $i'), findsOneWidget);
      }
    },
  );

  testWidgets('a second tap closes the list', (tester) async {
    await prepareDashboard(dash());
    await _pump(tester, container);
    final row = find.byKey(const ValueKey('admin-dash-tasks-Session Alpha'));
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.textContaining('Goal running one'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    for (final g in goals) {
      expect(find.textContaining(g), findsNothing);
    }
    expect(find.textContaining('item a'), findsNothing);
  });
}

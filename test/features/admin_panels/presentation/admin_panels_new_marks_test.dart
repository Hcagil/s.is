import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_seen_store.dart';
import 'package:sis/features/admin_panels/presentation/admin_dashboard_view.dart';
import 'package:sis/features/admin_panels/presentation/admin_talk_view.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../application/admin_fakes.dart';

/// Builds the widget under test inside a MaterialApp with the required
/// providers and theme.  The optional [size] can be used to override the
/// logical size of the view for tests that need a specific screen size.
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
        home: const AdminPanelsScreen(),
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

  // Unmounts the screen so its poll timer is gone before the test ends.
  void scene(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
  }

  /// Helper to create a talk message item.
  AdminItem talkMsg(String id, {String from = 'manager'}) => AdminItem(
    id: 'm:$id',
    kind: 'talk',
    seq: 1,
    removed: false,
    fields: {
      'id': id,
      'at': 1000,
      'from': from,
      'text': 'hello $id',
      'conv': 'c1',
    },
  );

  /// Helper to create a conversation item.
  final AdminItem conv = AdminItem(
    id: 'c:c1',
    kind: 'talk',
    seq: 1,
    removed: false,
    fields: {
      'id': 'c1',
      'topic': 'Topic',
      'at': 1000,
      'unread': false,
      'waiting': 0,
      'conv': true,
    },
  );

  /// Helper to create a task item.
  AdminItem taskItem(String id) => AdminItem(
    id: 't:$id',
    kind: 'task',
    seq: 1,
    removed: false,
    fields: {'id': id, 'name': 'Task $id', 'change': 'change $id'},
  );

  /// Finder for a badge with a given label and number.
  Finder badge(String label, String n) => find.descendant(
    of: find.widgetWithText(NavigationDestination, label),
    matching: find.text(n),
  );

  /// Expect that no badge exists for the given label.
  void expectNoBadge(String label) {
    expect(find.widgetWithText(NavigationDestination, label), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(NavigationDestination, label),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
  }

  /// Prepare initial snapshot with the given items.
  Future<void> prepareInitial(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
  }

  scene('bottom bar order is Dashboard, Talk, Questions, Tasks', (
    tester,
  ) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    const barKey = ValueKey('admin-bottom-bar');
    final positions = <String, Offset>{};
    for (final label in ['Dashboard', 'Talk', 'Questions', 'Tasks']) {
      final finder = find.descendant(
        of: find.byKey(barKey),
        matching: find.text(label),
      );
      final center = tester.getCenter(finder);
      positions[label] = center;
    }
    expect(
      positions['Dashboard']!.dx < positions['Talk']!.dx &&
          positions['Talk']!.dx < positions['Questions']!.dx &&
          positions['Questions']!.dx < positions['Tasks']!.dx,
      isTrue,
    );
  });

  scene('Dashboard is the first tab shown', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    expect(find.byType(AdminDashboardView), findsOneWidget);
    expect(find.byType(AdminTalkView), findsNothing);
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.selectedIndex, 0);
  });

  scene('a new question while on Dashboard shows 1 on Questions', (
    tester,
  ) async {
    await prepareInitial([qItem('q1'), conv]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [qItem('q2')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Questions', '1'), findsOneWidget);
    expectNoBadge('Talk');
    expectNoBadge('Tasks');
  });

  scene('two new Talk messages show 2 on Talk', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [talkMsg('a'), talkMsg('b')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Talk', '2'), findsOneWidget);
    expectNoBadge('Questions');
    expectNoBadge('Tasks');
  });

  scene('new tasks show their number on Tasks', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(
        2,
        2,
        cursor: 6,
        items: [taskItem('t1'), taskItem('t2'), taskItem('t3')],
      ),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Tasks', '3'), findsOneWidget);
    expectNoBadge('Talk');
    expectNoBadge('Questions');
  });

  scene('opening Questions clears its badge', (tester) async {
    await prepareInitial([qItem('q1'), conv]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [qItem('q2')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Questions', '1'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text('Questions'),
      ),
    );
    await tester.pumpAndSettle();
    expectNoBadge('Questions');
  });

  scene('zero new items shows no badge anywhere', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-bottom-bar')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
  });

  scene('a message the owner wrote does not count on Talk', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [talkMsg('o', from: 'owner')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expectNoBadge('Talk');
  });

  scene('items already counted are not counted again', (tester) async {
    await prepareInitial([qItem('q1'), conv]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [qItem('q2')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Questions', '1'), findsOneWidget);
    repo.fetchQueue.add([
      deltaRow(3, 3, cursor: 7, items: [qItem('q2')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(badge('Questions', '1'), findsOneWidget);
  });

  scene('badge only grows on tabs not currently open', (tester) async {
    await prepareInitial([qItem('q1'), conv]);
    await _pump(tester, container);
    // open Questions first
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text('Questions'),
      ),
    );
    await tester.pumpAndSettle();
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [qItem('q2')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expectNoBadge('Questions');
    // leaving the tab must not reveal a number: what arrived while it was open is seen
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text('Dashboard'),
      ),
    );
    await tester.pumpAndSettle();
    expectNoBadge('Questions');
  });

  scene(
    'after a restart the seen counts stay: no badge on Questions, new items still count',
    (tester) async {
      final seen = MemoryAdminSeenStore();
      final snaps = FakeAdminSnapshotStore();
      final unlock = FakeAdminUnlock();
      ProviderContainer build() => ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(unlock),
          adminSnapshotStoreProvider.overrideWithValue(snaps),
          adminSeenStoreProvider.overrideWithValue(seen),
        ],
      );
      final first = build();
      await prepareInitial([qItem('q1'), conv]);
      await _pump(tester, first);
      repo.fetchQueue.add([
        deltaRow(2, 2, cursor: 6, items: [qItem('q2')]),
      ]);
      await tester.pump(adminPollEvery);
      await tester.pumpAndSettle();
      expect(badge('Questions', '1'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('admin-bottom-bar')),
          matching: find.text('Questions'),
        ),
      );
      await tester.pumpAndSettle();
      expectNoBadge('Questions');
      // restart: same seen store and fakes, new container
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final second = build();
      repo.fetchQueue = [
        [
          snapRow(1, 1, cursor: 6, items: [qItem('q1'), qItem('q2'), conv]),
        ],
      ];
      await _pump(tester, second);
      expectNoBadge('Questions');
      repo.fetchQueue.add([
        deltaRow(3, 3, cursor: 8, items: [qItem('q3')]),
      ]);
      await tester.pump(adminPollEvery);
      await tester.pumpAndSettle();
      expect(badge('Questions', '1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
}

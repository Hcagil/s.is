import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';
import 'package:sis/features/admin_panels/presentation/admin_cards_view.dart';
import 'package:sis/features/admin_panels/presentation/admin_dashboard_view.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../application/admin_fakes.dart';

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
  final l = lookupAppLocalizations(const Locale('en'));

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

  void scene(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
  }

  AdminItem cardItem(String id, String oneLiner) => AdminItem(
    id: 'k:$id',
    kind: 'card',
    seq: 1,
    removed: false,
    fields: {
      'id': id,
      'type': 'rule',
      'state': 'active',
      'one_liner': oneLiner,
    },
  );

  AdminItem taskItem(String id) => AdminItem(
    id: 't:$id',
    kind: 'task',
    seq: 1,
    removed: false,
    fields: {'id': id, 'name': 'Task $id', 'change': 'change $id'},
  );

  Future<void> openCardsTab(WidgetTester t) async {
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text(l.adminCards),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> prepareInitial(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
  }

  scene('Cards is the fifth tab', (tester) async {
    await prepareInitial([cardItem('C-1', 'alpha rule')]);
    await _pump(tester, container);
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.destinations.length, 5);
    final dest = navBar.destinations[4] as NavigationDestination;
    expect(dest.label, l.adminCards);
    final icon = dest.icon as Icon;
    expect(icon.icon, Icons.style_outlined);
    final barKey = const ValueKey('admin-bottom-bar');
    final cardsDx = tester
        .getCenter(
          find.descendant(
            of: find.byKey(barKey),
            matching: find.text(l.adminCards),
          ),
        )
        .dx;
    final tasksDx = tester
        .getCenter(
          find.descendant(of: find.byKey(barKey), matching: find.text('Tasks')),
        )
        .dx;
    expect(cardsDx > tasksDx, isTrue);
  });

  scene('Cards tab shows the cards view', (tester) async {
    await prepareInitial([cardItem('C-1', 'alpha rule')]);
    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-panel-4')), findsNothing);
    await openCardsTab(tester);
    expect(find.byKey(const ValueKey('admin-panel-4')), findsOneWidget);
    expect(find.byType(AdminCardsView), findsOneWidget);
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.selectedIndex, 4);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byType(AdminDashboardView), findsNothing);
  });

  scene('Cards tab has no badge even when a new card arrives', (tester) async {
    await prepareInitial([cardItem('C-1', 'alpha rule')]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [cardItem('C-2', 'beta rule')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    final barKey = const ValueKey('admin-bottom-bar');
    expect(
      find.descendant(
        of: find.widgetWithText(NavigationDestination, l.adminCards),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: find.byKey(barKey), matching: find.byType(Badge)),
      findsNothing,
    );
    await openCardsTab(tester);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
  });

  scene('visiting Cards does not clear another tab badge', (tester) async {
    await prepareInitial([cardItem('C-1', 'alpha rule')]);
    await _pump(tester, container);
    repo.fetchQueue.add([
      deltaRow(2, 2, cursor: 6, items: [taskItem('t1')]),
    ]);
    await tester.pump(adminPollEvery);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(NavigationDestination, 'Tasks'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await openCardsTab(tester);
    expect(
      find.descendant(
        of: find.widgetWithText(NavigationDestination, 'Tasks'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Cards tab is hidden until unlock', (tester) async {
    final fakeUnlock = FakeAdminUnlock()..result = AdminUnlockResult.cancelled;
    final customContainer = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(fakeUnlock),
        adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
      ],
    );
    await prepareInitial([cardItem('C-1', 'alpha rule')]);
    await _pump(tester, customContainer);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text(l.adminCards), findsNothing);
    expect(find.byKey(const ValueKey('admin-panel-4')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    customContainer.dispose();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_cards_view.dart';
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
  bool settle = true,
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
        home: Scaffold(body: const AdminCardsView()),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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

  /// Helper to prepare a cards snapshot with the given items.
  Future<void> prepareCards(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
    // keep provider alive
    container.listen(adminPanelsProvider, (_, _) {});
    await container.read(adminPanelsProvider.notifier).open('r');
    await container.read(adminPanelsProvider.notifier).refresh();
    expect(container.read(adminPanelsProvider).hasSnapshot, isTrue);
  }

  /// Fixture helper
  AdminItem cardItem(String id, Map<String, Object?> f) => AdminItem(
    id: 'k:$id',
    kind: 'card',
    seq: 1,
    removed: false,
    fields: {'id': id, ...f},
  );

  Finder tile(String id) => find.byKey(ValueKey('admin-card-tile-$id'));

  Future<void> tapKey(WidgetTester t, String k) async {
    // Chips live in the filter sheet: open it first when it is closed.
    if (find
        .byKey(const ValueKey('admin-cards-filter-sheet'))
        .evaluate()
        .isEmpty) {
      await t.tap(find.byKey(const ValueKey('admin-cards-filter-button')));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(ValueKey(k)));
    await t.pumpAndSettle();
  }

  void expectOnly(List<String> ids) {
    for (final id in ['C-1', 'C-2', 'C-3', 'C-4']) {
      expect(tile(id), ids.contains(id) ? findsOneWidget : findsNothing);
    }
  }

  testWidgets('no chips on the main screen', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M, L',
        'one_liner': 'alpha rule',
      }),
      cardItem('C-2', {
        'type': 'rule',
        'state': 'proposed',
        'applies': 'L',
        'one_liner': 'beta rule',
      }),
      cardItem('C-3', {
        'type': 'app',
        'state': 'active',
        'area': 'release',
        'one_liner': 'gamma app',
      }),
      cardItem('C-4', {
        'type': 'app',
        'state': 'proposed',
        'area': 'build',
        'one_liner': 'delta app',
      }),
    ]);
    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-cards-state-all')), findsNothing);
    expect(find.byKey(const ValueKey('admin-cards-type-all')), findsNothing);
    expect(
      find.byKey(const ValueKey('admin-cards-state-active')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-cards-filter-sheet')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('admin-cards-search')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-cards-filter-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-cards-filter-badge')),
      findsNothing,
    );
  });

  testWidgets('button opens sheet with 3 groups', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M, L',
        'one_liner': 'alpha rule',
      }),
      cardItem('C-2', {
        'type': 'rule',
        'state': 'proposed',
        'applies': 'L',
        'one_liner': 'beta rule',
      }),
      cardItem('C-3', {
        'type': 'app',
        'state': 'active',
        'area': 'release',
        'one_liner': 'gamma app',
      }),
      cardItem('C-4', {
        'type': 'app',
        'state': 'proposed',
        'area': 'build',
        'one_liner': 'delta app',
      }),
    ]);
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('admin-cards-filter-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('admin-cards-filter-sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-cards-filter-sheet-title')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-sheet-title')),
        matching: find.text('Filters'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('admin-cards-state-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-type-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-value-all')), findsNothing);
    await tapKey(tester, 'admin-cards-type-rule');
    expect(find.byKey(const ValueKey('admin-cards-value-all')), findsOneWidget);
  });

  testWidgets('chips filter at once and badge counts', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M, L',
        'one_liner': 'alpha rule',
      }),
      cardItem('C-2', {
        'type': 'rule',
        'state': 'proposed',
        'applies': 'L',
        'one_liner': 'beta rule',
      }),
      cardItem('C-3', {
        'type': 'app',
        'state': 'active',
        'area': 'release',
        'one_liner': 'gamma app',
      }),
      cardItem('C-4', {
        'type': 'app',
        'state': 'proposed',
        'area': 'build',
        'one_liner': 'delta app',
      }),
    ]);
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('admin-cards-filter-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('admin-cards-filter-badge')),
      findsNothing,
    );
    await tapKey(tester, 'admin-cards-state-proposed');
    expectOnly(['C-2', 'C-4']);
    expect(
      find.byKey(const ValueKey('admin-cards-filter-badge')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-badge')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'admin-cards-type-rule');
    expectOnly(['C-2']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-badge')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'admin-cards-value-L');
    expectOnly(['C-2']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-badge')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'admin-cards-type-app');
    expectOnly(['C-4']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-badge')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'admin-cards-type-all');
    expectOnly(['C-2', 'C-4']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-badge')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'admin-cards-state-all');
    expectOnly(['C-1', 'C-2', 'C-3', 'C-4']);
    expect(
      find.byKey(const ValueKey('admin-cards-filter-badge')),
      findsNothing,
    );
  });

  testWidgets('swipe down closes the sheet and keeps filters', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M, L',
        'one_liner': 'alpha rule',
      }),
      cardItem('C-2', {
        'type': 'rule',
        'state': 'proposed',
        'applies': 'L',
        'one_liner': 'beta rule',
      }),
      cardItem('C-3', {
        'type': 'app',
        'state': 'active',
        'area': 'release',
        'one_liner': 'gamma app',
      }),
      cardItem('C-4', {
        'type': 'app',
        'state': 'proposed',
        'area': 'build',
        'one_liner': 'delta app',
      }),
    ]);
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('admin-cards-filter-button')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'admin-cards-state-active');
    await tester.drag(
      find.byKey(const ValueKey('admin-cards-filter-sheet')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('admin-cards-filter-sheet')),
      findsNothing,
    );
    expectOnly(['C-1', 'C-3']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-cards-filter-badge')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('semantics label', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M, L',
        'one_liner': 'alpha rule',
      }),
      cardItem('C-2', {
        'type': 'rule',
        'state': 'proposed',
        'applies': 'L',
        'one_liner': 'beta rule',
      }),
      cardItem('C-3', {
        'type': 'app',
        'state': 'active',
        'area': 'release',
        'one_liner': 'gamma app',
      }),
      cardItem('C-4', {
        'type': 'app',
        'state': 'proposed',
        'area': 'build',
        'one_liner': 'delta app',
      }),
    ]);
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('admin-cards-filter-button')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'admin-cards-state-proposed');
    await tapKey(tester, 'admin-cards-type-app');
    await tester.drag(
      find.byKey(const ValueKey('admin-cards-filter-sheet')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    final h = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Filters, 2 on'), findsOneWidget);
    h.dispose();
  });
}

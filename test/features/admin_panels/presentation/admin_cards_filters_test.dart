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

  final l = lookupAppLocalizations(const Locale('en'));

  Finder tile(String id) => find.byKey(ValueKey('admin-card-tile-$id'));

  Future<void> tapKey(WidgetTester t, String k) async {
    await t.tap(find.byKey(ValueKey(k)));
    await t.pumpAndSettle();
  }

  Future<void> search(WidgetTester t, String q) async {
    await t.enterText(find.byKey(const ValueKey('admin-cards-search')), q);
    await t.pumpAndSettle();
  }

  void expectOnly(List<String> ids) {
    for (final id in ['C-1', 'C-2', 'C-3', 'C-4']) {
      expect(tile(id), ids.contains(id) ? findsOneWidget : findsNothing);
    }
  }

  testWidgets('initial state shows all tiles and no value chips', (
    tester,
  ) async {
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
    expectOnly(['C-1', 'C-2', 'C-3', 'C-4']);
    expect(find.byKey(const ValueKey('admin-cards-value-all')), findsNothing);
  });

  testWidgets('state filter works', (tester) async {
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
    await tapKey(tester, 'admin-cards-state-proposed');
    expectOnly(['C-2', 'C-4']);
    await tapKey(tester, 'admin-cards-state-active');
    expectOnly(['C-1', 'C-3']);
    await tapKey(tester, 'admin-cards-state-all');
    expectOnly(['C-1', 'C-2', 'C-3', 'C-4']);
  });

  testWidgets('type filter works', (tester) async {
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
    await tapKey(tester, 'admin-cards-type-rule');
    expectOnly(['C-1', 'C-2']);
    await tapKey(tester, 'admin-cards-type-app');
    expectOnly(['C-3', 'C-4']);
    await tapKey(tester, 'admin-cards-type-all');
    expectOnly(['C-1', 'C-2', 'C-3', 'C-4']);
  });

  testWidgets('rule value chips appear and filter correctly', (tester) async {
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
    await tapKey(tester, 'admin-cards-type-rule');
    expect(find.byKey(const ValueKey('admin-cards-value-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-value-M')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-value-L')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-cards-value-release')),
      findsNothing,
    );
    await tapKey(tester, 'admin-cards-value-M');
    expectOnly(['C-1']);
    await tapKey(tester, 'admin-cards-value-L');
    expectOnly(['C-1', 'C-2']);
    await tapKey(tester, 'admin-cards-value-all');
    expectOnly(['C-1', 'C-2']);
  });

  testWidgets('app value chips appear and filter correctly', (tester) async {
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
    await tapKey(tester, 'admin-cards-type-app');
    expect(
      find.byKey(const ValueKey('admin-cards-value-release')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-cards-value-build')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('admin-cards-value-M')), findsNothing);
    await tapKey(tester, 'admin-cards-value-build');
    expectOnly(['C-4']);
  });

  testWidgets('no value chips when the chosen type has no values', (
    tester,
  ) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M',
        'one_liner': 'alpha rule',
      }),
      cardItem('C-2', {
        'type': 'app',
        'state': 'active',
        'one_liner': 'beta app',
      }),
    ]);
    await _pump(tester, container);
    await tapKey(tester, 'admin-cards-type-app');
    expect(find.byKey(const ValueKey('admin-cards-value-all')), findsNothing);
    expect(tile('C-2'), findsOneWidget);
    expect(tile('C-1'), findsNothing);
    await tapKey(tester, 'admin-cards-type-rule');
    expect(find.byKey(const ValueKey('admin-cards-value-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-value-M')), findsOneWidget);
  });

  testWidgets('changing type resets value filter', (tester) async {
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
    await tapKey(tester, 'admin-cards-type-rule');
    await tapKey(tester, 'admin-cards-value-M');
    expectOnly(['C-1']);
    await tapKey(tester, 'admin-cards-type-app');
    expectOnly(['C-3', 'C-4']);
    expect(find.byKey(const ValueKey('admin-cards-value-M')), findsNothing);
  });

  testWidgets('AND filtering with state, type and search', (tester) async {
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
    await tapKey(tester, 'admin-cards-state-proposed');
    await tapKey(tester, 'admin-cards-type-app');
    expectOnly(['C-4']);
    await search(tester, 'gamma');
    expect(find.text(l.adminCardsNoMatch), findsOneWidget);
    await search(tester, '');
    expectOnly(['C-4']);
  });

  testWidgets('search with type filter shows no match when none', (
    tester,
  ) async {
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
    await search(tester, 'rule');
    expectOnly(['C-1', 'C-2']);
    await tapKey(tester, 'admin-cards-type-app');
    expect(find.text(l.adminCardsNoMatch), findsOneWidget);
  });
}

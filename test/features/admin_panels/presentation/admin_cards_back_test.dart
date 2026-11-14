import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_cards_view.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../application/admin_fakes.dart';

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

  /// Fixture cards
  List<AdminItem> fixture() => [
    cardItem('C-1', {
      'type': 'rule',
      'state': 'active',
      'applies': 'M, L',
      'one_liner': 'alpha first rule',
    }),
    cardItem('C-2', {
      'type': 'app',
      'state': 'proposed',
      'one_liner': 'minimal app',
    }),
    cardItem('C-3', {
      'type': 'app',
      'state': 'active',
      'area': 'release',
      'one_liner': 'third app',
    }),
  ];

  Future<void> openCard(WidgetTester t, String id) async {
    await t.tap(find.byKey(ValueKey('admin-card-tile-$id')));
    await t.pumpAndSettle();
  }

  testWidgets('back button returns to list', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-1');
    await tester.tap(find.byKey(const ValueKey('admin-card-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-detail-C-1')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-search')), findsOneWidget);
  });

  testWidgets('back keeps filters and query', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('admin-cards-state-proposed')));
    await tester.tap(find.byKey(const ValueKey('admin-cards-type-app')));
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'minimal',
    );
    await tester.pumpAndSettle();
    await openCard(tester, 'C-2');
    await tester.tap(find.byKey(const ValueKey('admin-card-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsNothing);
    final tf = tester.widget<TextField>(
      find.byKey(const ValueKey('admin-cards-search')),
    );
    expect(tf.controller!.text, 'minimal');
  });

  testWidgets('system back from detail returns to list', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-1');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-detail-C-1')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
  });

  testWidgets('system back with no card open leaves the screen', (
    tester,
  ) async {
    await prepareCards(fixture());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: sisTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                key: const ValueKey('go'),
                onPressed: () => Navigator.of(c).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: AdminCardsView()),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCardsView), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AdminCardsView), findsNothing);
    expect(find.byKey(const ValueKey('go')), findsOneWidget);
  });

  testWidgets('system back after opening card', (tester) async {
    await prepareCards(fixture());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: sisTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                key: const ValueKey('go'),
                onPressed: () => Navigator.of(c).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: AdminCardsView()),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();
    await openCard(tester, 'C-1');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AdminCardsView), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AdminCardsView), findsNothing);
  });

  testWidgets('removed open card shows list', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-1');
    repo.fetchQueue.add([
      deltaRow(
        2,
        2,
        cursor: 6,
        items: [
          AdminItem(
            id: 'k:C-1',
            kind: 'card',
            seq: 2,
            removed: true,
            fields: const {},
          ),
        ],
      ),
    ]);
    await container.read(adminPanelsProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-detail-C-1')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/app/loading.dart';

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

  testWidgets('progress line before snapshot', (tester) async {
    await _pump(tester, container, settle: false);
    expect(find.byType(SisProgressLine), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-search')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('empty list shows empty text', (tester) async {
    await prepareCards([
      AdminItem(
        id: 't:T1',
        kind: 'task',
        seq: 1,
        removed: false,
        fields: {'id': 'T1', 'name': 'x', 'change': 'y'},
      ),
    ]);
    await _pump(tester, container);
    expect(find.text(l.adminCardsEmpty), findsOneWidget);
  });

  testWidgets('rows show correct tiles and labels', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'type': 'rule',
        'state': 'active',
        'applies': 'M, L',
        'when': ['lead'],
        'one_liner': 'alpha first rule',
        'words': ['owner said beta'],
        'allows': 'do gamma',
        'forbids': 'avoid delta',
      }),
      cardItem('C-2', {
        'type': 'rule',
        'state': 'proposed',
        'applies': 'L',
        'one_liner': 'second rule',
      }),
      cardItem('C-3', {
        'type': 'app',
        'state': 'active',
        'area': 'release',
        'one_liner': 'third app',
      }),
    ]);
    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsOneWidget);
    expect(find.text('alpha first rule'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-card-tile-C-1')),
        matching: find.text(l.adminCardsActive),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('admin-card-tile-C-2')),
        matching: find.text(l.adminCardsProposed),
      ),
      findsOneWidget,
    );
  });

  testWidgets('rows are sorted by id', (tester) async {
    await prepareCards([
      cardItem('C-3', {'one_liner': 'third'}),
      cardItem('C-1', {'one_liner': 'first'}),
      cardItem('C-2', {'one_liner': 'second'}),
    ]);
    await _pump(tester, container);
    final c1 = tester.getTopLeft(
      find.byKey(const ValueKey('admin-card-tile-C-1')),
    );
    final c2 = tester.getTopLeft(
      find.byKey(const ValueKey('admin-card-tile-C-2')),
    );
    final c3 = tester.getTopLeft(
      find.byKey(const ValueKey('admin-card-tile-C-3')),
    );
    expect(c1.dy < c2.dy && c2.dy < c3.dy, isTrue);
  });

  testWidgets('search by id filters tiles', (tester) async {
    await prepareCards([
      cardItem('C-1', {'one_liner': 'first'}),
      cardItem('C-2', {'one_liner': 'second'}),
      cardItem('C-3', {'one_liner': 'third'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'c-2',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsNothing);
  });

  testWidgets('search matches one_liner (case-insensitive)', (tester) async {
    await prepareCards([
      cardItem('C-1', {'one_liner': 'alpha first rule'}),
      cardItem('C-2', {'one_liner': 'second rule'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'FIRST',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsNothing);
  });

  testWidgets('search matches words', (tester) async {
    await prepareCards([
      cardItem('C-1', {
        'one_liner': 'alpha',
        'words': ['owner said beta'],
      }),
      cardItem('C-2', {'one_liner': 'second'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'beta',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsNothing);
  });

  testWidgets('search matches allows', (tester) async {
    await prepareCards([
      cardItem('C-1', {'one_liner': 'alpha', 'allows': 'do gamma'}),
      cardItem('C-2', {'one_liner': 'second'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'gamma',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsNothing);
  });

  testWidgets('search matches forbids', (tester) async {
    await prepareCards([
      cardItem('C-1', {'one_liner': 'alpha', 'forbids': 'avoid delta'}),
      cardItem('C-2', {'one_liner': 'second'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'delta',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsNothing);
  });

  testWidgets('padded query trims whitespace', (tester) async {
    await prepareCards([
      cardItem('C-3', {'one_liner': 'third app'}),
      cardItem('C-1', {'one_liner': 'first'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      '  third  ',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsNothing);
  });

  testWidgets('clearing search shows all tiles', (tester) async {
    await prepareCards([
      cardItem('C-1', {'one_liner': 'first'}),
      cardItem('C-2', {'one_liner': 'second'}),
      cardItem('C-3', {'one_liner': 'third'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'c-2',
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      '',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsOneWidget);
    // whitespace only
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      '   ',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-3')), findsOneWidget);
  });

  testWidgets('no match shows no match text', (tester) async {
    await prepareCards([
      cardItem('C-1', {'one_liner': 'first'}),
      cardItem('C-2', {'one_liner': 'second'}),
    ]);
    await _pump(tester, container);
    await tester.enterText(
      find.byKey(const ValueKey('admin-cards-search')),
      'zzzzqq',
    );
    await tester.pumpAndSettle();
    expect(find.text(l.adminCardsNoMatch), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-tile-C-1')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsNothing);
    expect(find.byKey(const ValueKey('admin-cards-search')), findsOneWidget);
  });
}

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

  /// Fixture cards
  List<AdminItem> fixture() => [
    cardItem('C-1', {
      'type': 'rule',
      'state': 'active',
      'applies': 'M, L',
      'when': ['lead', 'worker'],
      'one_liner': 'alpha first rule',
      'words': ['owner said beta', 'second quote gamma'],
      'allows': 'do delta',
      'forbids': 'avoid epsilon',
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

  Finder sel(String s) =>
      find.byWidgetPredicate((w) => w is SelectableText && w.data == s);

  Future<void> openCard(WidgetTester t, String id) async {
    await t.tap(find.byKey(ValueKey('admin-card-tile-$id')));
    await t.pumpAndSettle();
  }

  testWidgets('open C-1 shows detail and hides others', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-1');
    expect(find.byKey(const ValueKey('admin-card-detail-C-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-cards-search')), findsNothing);
    expect(find.byKey(const ValueKey('admin-card-tile-C-2')), findsNothing);
  });

  testWidgets('detail of C-1 shows all fields', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-1');
    expect(sel('alpha first rule'), findsOneWidget);
    expect(sel('${l.adminCardsRule} - ${l.adminCardsActive}'), findsOneWidget);
    expect(sel('M, L'), findsOneWidget);
    expect(sel('lead, worker'), findsOneWidget);
    expect(sel('owner said beta\nsecond quote gamma'), findsOneWidget);
    expect(sel('do delta'), findsOneWidget);
    expect(sel('avoid epsilon'), findsOneWidget);
    expect(find.text(l.adminCardApplies), findsOneWidget);
    expect(find.text(l.adminCardWhen), findsOneWidget);
    expect(find.text(l.adminCardWords), findsOneWidget);
    expect(find.text(l.adminCardAllows), findsOneWidget);
    expect(find.text(l.adminCardForbids), findsOneWidget);
    expect(find.text(l.adminCardArea), findsNothing);
  });

  testWidgets('detail of C-2 shows minimal fields', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-2');
    expect(sel('minimal app'), findsOneWidget);
    expect(sel('${l.adminCardsApp} - ${l.adminCardsProposed}'), findsOneWidget);
    expect(find.text(l.adminCardApplies), findsNothing);
    expect(find.text(l.adminCardArea), findsNothing);
    expect(find.text(l.adminCardWhen), findsNothing);
    expect(find.text(l.adminCardWords), findsNothing);
    expect(find.text(l.adminCardAllows), findsNothing);
    expect(find.text(l.adminCardForbids), findsNothing);
  });

  testWidgets('detail of C-3 shows area only', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-3');
    expect(find.text(l.adminCardArea), findsOneWidget);
    expect(sel('release'), findsOneWidget);
    expect(find.text(l.adminCardApplies), findsNothing);
  });

  testWidgets('detail is read-only', (tester) async {
    await prepareCards(fixture());
    await _pump(tester, container);
    await openCard(tester, 'C-1');
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-card-back')), findsOneWidget);
    expect(repo.sent, isEmpty);
    expect(find.byType(SelectableText), findsAtLeastNWidgets(7));
  });
}

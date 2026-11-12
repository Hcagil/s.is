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
/// required providers and theme.
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) async {
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

  testWidgets('shows stale text when stale flag true', (tester) async {
    await prepareDashboard({'working': [], 'sessions': [], 'stale': true});

    await _pump(tester, container);
    final l = AppLocalizations.of(
      tester.element(find.byType(AdminDashboardView)),
    );
    expect(find.byKey(const ValueKey('admin-dash-stale')), findsOneWidget);
    expect(find.text(l.adminDashboardStale), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-dash-work-0')), findsNothing);
  });

  testWidgets('shows work rows when not stale and working non-empty', (
    tester,
  ) async {
    await prepareDashboard({
      'working': ['fix the login'],
      'sessions': [],
    });

    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-dash-stale')), findsNothing);
    expect(find.byKey(const ValueKey('admin-dash-work-0')), findsOneWidget);
  });

  testWidgets('shows work rows when stale flag false and working non-empty', (
    tester,
  ) async {
    await prepareDashboard({
      'working': ['x'],
      'sessions': [],
      'stale': false,
    });

    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-dash-stale')), findsNothing);
    expect(find.byKey(const ValueKey('admin-dash-work-0')), findsOneWidget);
  });

  testWidgets('shows stale text even if working list non-empty', (
    tester,
  ) async {
    await prepareDashboard({
      'working': ['x'],
      'sessions': [],
      'stale': true,
    });

    await _pump(tester, container);
    expect(find.byKey(const ValueKey('admin-dash-stale')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-dash-work-0')), findsNothing);
  });
}

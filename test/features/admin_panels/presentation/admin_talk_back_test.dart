import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
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
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('base-open'),
                onPressed: () => showAdminPanels(ctx),
                child: const Text('Base'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // open the Admin Panels route
  await tester.tap(find.byKey(const ValueKey('base-open')));
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

  /// Prepare initial snapshot with the given items.
  Future<void> prepareInitial(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
  }

  /// Helper to open the Talk list.
  Future<void> openTalk(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('admin-bottom-bar')),
        matching: find.text('Talk'),
      ),
    );
    await tester.pumpAndSettle();
  }

  scene('system back inside a Talk conversation returns to the Talk list', (
    tester,
  ) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.tap(find.byKey(const ValueKey('admin-conv-tile-c1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('admin-talk-back')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AdminPanelsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-conv-tile-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-talk-back')), findsNothing);
    expect(find.byKey(const ValueKey('base-open')), findsNothing);
  });

  scene('system back on the Talk list leaves Admin Panels', (tester) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    await openTalk(tester);
    expect(find.byKey(const ValueKey('admin-conv-tile-c1')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AdminPanelsScreen), findsNothing);
    expect(find.byKey(const ValueKey('base-open')), findsOneWidget);
  });
}

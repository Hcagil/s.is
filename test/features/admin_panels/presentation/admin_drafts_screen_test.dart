import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';

import '../../../support/spy_admin_draft_store.dart';

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
  late SpyAdminDraftStore spy;

  setUp(() {
    repo = FakeAdminRepository();
    spy = SpyAdminDraftStore();
    container = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
        adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
        adminDraftStoreProvider.overrideWithValue(spy),
      ],
    );
  });

  // Unmounts the screen so its poll timer is gone before the test ends.
  void scene(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
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

  Future<void> typeInConv(WidgetTester tester, String text) async {
    await prepareInitial([conv]);
    await _pump(tester, container);
    await openTalk(tester);
    await tester.tap(find.byKey(const ValueKey('admin-conv-tile-c1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('admin-talk-input')),
      text,
    );
  }

  for (final state in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
    scene('${state.name} saves the typed text at once', (tester) async {
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await typeInConv(tester, 'before the call');
      expect(spy.saved, isEmpty);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
      await tester.pump(const Duration(milliseconds: 50));
      expect(spy.saved, {'talk:c1': 'before the call'});
    });
  }

  scene('leaving the panel and coming back restores the text', (tester) async {
    await typeInConv(tester, 'half a thought');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('base-open')), findsOneWidget);
    expect(spy.saved, {'talk:c1': 'half a thought'});
    await prepareInitial([conv]);
    await tester.tap(find.byKey(const ValueKey('base-open')));
    await tester.pumpAndSettle();
    await openTalk(tester);
    await tester.tap(find.byKey(const ValueKey('admin-conv-tile-c1')));
    await tester.pumpAndSettle();
    expect(find.text('half a thought'), findsOneWidget);
  });
}

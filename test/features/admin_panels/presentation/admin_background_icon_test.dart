// test/features/admin_panels/presentation/admin_background_icon_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_entry_provider.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/presentation/admin_entry_button.dart';
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
        home: Scaffold(appBar: AppBar(actions: const [AdminEntryButton()])),
      ),
    ),
  );
  await tester.pump();
}

Future<ProviderContainer> mount(
  WidgetTester t,
  Override entry,
  FakeAdminRepository repo,
  FakeAdminUnlock unlock,
) async {
  final c = ProviderContainer(
    overrides: [
      entry,
      adminPanelsRepositoryProvider.overrideWithValue(repo),
      adminUnlockProvider.overrideWithValue(unlock),
      adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
      adminSeenStoreProvider.overrideWithValue(FakeAdminSeenStore()),
    ],
  );
  addTearDown(c.dispose);
  c.listen(adminPanelsProvider, (_, _) {});
  await _pump(t, c);
  return c;
}

void main() {
  testWidgets('owner: the count is fetched at first frame without the unlock', (
    tester,
  ) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repo = FakeAdminRepository()
      ..fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
    final unlock = FakeAdminUnlock();
    final c = await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => true),
      repo,
      unlock,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(repo.fetchCalls, isNotEmpty);
    expect(unlock.calls, 0);
    expect(c.read(adminPanelsProvider).hasSnapshot, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('not the owner: no fetch ever', (tester) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repo = FakeAdminRepository()
      ..fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
    final unlock = FakeAdminUnlock();
    await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => false),
      repo,
      unlock,
    );
    await tester.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls, isEmpty);
    expect(repo.statusCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('entry still loading: no fetch', (tester) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repo = FakeAdminRepository()
      ..fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
    final unlock = FakeAdminUnlock();
    await mount(
      tester,
      adminEntryProvider.overrideWith((ref) => Completer<bool>().future),
      repo,
      unlock,
    );
    await tester.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('entry becomes owner later: the fetch starts then', (
    tester,
  ) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repo = FakeAdminRepository()
      ..fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
    final unlock = FakeAdminUnlock();
    final comp = Completer<bool>();
    await mount(
      tester,
      adminEntryProvider.overrideWith((ref) => comp.future),
      repo,
      unlock,
    );
    await tester.pump();
    expect(repo.fetchCalls, isEmpty);
    comp.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(repo.fetchCalls, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('polls every 5 seconds', (tester) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repo = FakeAdminRepository()
      ..fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
    final unlock = FakeAdminUnlock();
    await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => true),
      repo,
      unlock,
    );
    await tester.pump(const Duration(milliseconds: 100));
    final base = repo.fetchCalls.length;
    await tester.pump(const Duration(seconds: 4));
    expect(repo.fetchCalls.length, base);
    await tester.pump(const Duration(seconds: 1));
    expect(repo.fetchCalls.length, base + 1);
    await tester.pump(const Duration(seconds: 5));
    expect(repo.fetchCalls.length, base + 2);
    await tester.pumpWidget(const SizedBox());
  });
}

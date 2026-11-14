// test/features/admin_panels/presentation/admin_background_lifecycle_test.dart
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
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

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
  FakeAdminUnlock unlock, {
  FakeAdminSnapshotStore? store,
}) async {
  final c = ProviderContainer(
    overrides: [
      entry,
      adminPanelsRepositoryProvider.overrideWithValue(repo),
      adminUnlockProvider.overrideWithValue(unlock),
      adminSnapshotStoreProvider.overrideWithValue(
        store ?? FakeAdminSnapshotStore(),
      ),
      adminSeenStoreProvider.overrideWithValue(FakeAdminSeenStore()),
    ],
  );
  addTearDown(c.dispose);
  c.listen(adminPanelsProvider, (_, _) {});
  await _pump(t, c);
  return c;
}

class _GatedRepo extends FakeAdminRepository {
  final Completer<void> gate = Completer<void>();
  @override
  Future<Result<List<AdminRow>>> fetch(int afterId) async {
    await gate.future;
    return super.fetch(afterId);
  }
}

void main() {
  testWidgets(
    'paused clears the snapshot and stops the poll; resumed restarts',
    (tester) async {
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
      final c = await mount(
        tester,
        adminEntryProvider.overrideWith((ref) async => true),
        repo,
        FakeAdminUnlock(),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.read(adminPanelsProvider).hasSnapshot, isTrue);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      expect(c.read(adminPanelsProvider).hasSnapshot, isFalse);
      final n = repo.fetchCalls.length;
      await tester.pump(const Duration(seconds: 30));
      expect(repo.fetchCalls.length, n);
      repo.fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.fetchCalls.length, greaterThan(n));
      expect(c.read(adminPanelsProvider).hasSnapshot, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('hidden stops the poll', (tester) async {
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
    final c = await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => true),
      repo,
      FakeAdminUnlock(),
    );
    await tester.pump(const Duration(milliseconds: 100));
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );
    await tester.pump();
    expect(c.read(adminPanelsProvider).hasSnapshot, isFalse);
    final n = repo.fetchCalls.length;
    await tester.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls.length, n);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inactive keeps the poll', (tester) async {
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
    final c = await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => true),
      repo,
      FakeAdminUnlock(),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final base = repo.fetchCalls.length;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.inactive,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(repo.fetchCalls.length, greaterThan(base));
    expect(c.read(adminPanelsProvider).hasSnapshot, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('removing the icon stops the poll', (tester) async {
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
    await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => true),
      repo,
      FakeAdminUnlock(),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final n = repo.fetchCalls.length;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls.length, n);
  });

  testWidgets('a lock during an in-flight background fetch drops the result', (
    tester,
  ) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repo = _GatedRepo()
      ..fetchQueue = [
        [
          snapRow(1, 1, items: [qItem('Q-1')]),
        ],
      ];
    final store = FakeAdminSnapshotStore();
    final c = await mount(
      tester,
      adminEntryProvider.overrideWith((ref) async => true),
      repo,
      FakeAdminUnlock(),
      store: store,
    );
    await tester.pump(const Duration(milliseconds: 100));
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    repo.gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(c.read(adminPanelsProvider).hasSnapshot, isFalse);
    expect(store.saveCalls, 0);
    final n = repo.fetchCalls.length;
    await tester.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls.length, n);
    await tester.pumpWidget(const SizedBox());
  });
}

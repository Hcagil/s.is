import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

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
        home: const AdminPanelsScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  late ProviderContainer container;
  late HeldRepo repo;

  setUp(() {
    repo = HeldRepo();
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

  /// Helper to expect the connection icon state.
  void expectConn(String s) {
    for (final k in ['connected', 'connecting', 'offline']) {
      expect(
        find.byKey(ValueKey('admin-conn-$k')),
        k == s ? findsOneWidget : findsNothing,
        reason: 'icon state $k',
      );
    }
  }

  /// Snapshot row helper.
  AdminRow snapRow1() => snapRow(1, 1, cursor: 5, items: [qItem('q1')]);

  // Scene 1: pressing the offline icon fetches at once
  scene('pressing the offline icon fetches at once', (tester) async {
    repo.fetchFail = Err(NetworkFailure('x'));
    await _pump(tester, container);
    expectConn('offline');
    repo.fetchFail = null;
    repo.fetchQueue = [
      [snapRow1()],
    ];
    final before = repo.fetchCalls.length;
    await tester.tap(find.byKey(const ValueKey('admin-conn-offline')));
    await tester.pump();
    await tester.pump();
    expect(repo.fetchCalls.length, before + 1);
    expectConn('connected');
  });

  // Scene 2: the icon turns orange at once while the fetch runs
  scene('the icon turns orange at once while the fetch runs', (tester) async {
    repo.fetchFail = Err(NetworkFailure('x'));
    await _pump(tester, container);
    expectConn('offline');
    repo.fetchFail = null;
    repo.fetchHold = Completer();
    await tester.tap(find.byKey(const ValueKey('admin-conn-offline')));
    await tester.pump();
    expectConn('connecting');
    repo.fetchHold!.complete(const Ok(<AdminRow>[]));
    repo.fetchHold = null;
    await tester.pump();
    await tester.pump();
    expectConn('connected');
  });
}

/// Fake repository that allows controlled failures and holds.
class HeldRepo extends FakeAdminRepository {
  Completer<Result<List<AdminRow>>>? fetchHold;
  Result<List<AdminRow>>? fetchFail;
  Result<AdminStatus?>? statusFail;

  @override
  Future<Result<List<AdminRow>>> fetch(int afterId) {
    if (fetchFail != null) {
      fetchCalls.add(afterId);
      return Future.value(fetchFail!);
    }
    final h = fetchHold;
    if (h != null) {
      fetchCalls.add(afterId);
      return h.future;
    }
    return super.fetch(afterId);
  }

  @override
  Future<Result<AdminStatus?>> status() {
    final f = statusFail;
    if (f != null) {
      statusCalls++;
      return Future.value(f);
    }
    return super.status();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
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

  bool hasSnap() => container.read(adminPanelsProvider).hasSnapshot;
  bool failed() => container.read(adminPanelsProvider).failure != null;

  /// Helper to advance one poll round.
  Future<void> nextRound(WidgetTester t) async {
    await t.pump(adminPollEvery);
    await t.pump();
    await t.pump();
  }

  /// Snapshot row helper.
  AdminRow snapRow1() => snapRow(1, 1, cursor: 5, items: [qItem('q1')]);

  /// Dashboard item for test 6.
  final AdminItem dashboardItem = AdminItem(
    id: 'dashboard',
    kind: 'dashboard',
    seq: 1,
    removed: false,
    fields: {'working': [], 'sessions': [], 'stale': true},
  );

  scene('orange while the first round runs, green when it works', (
    tester,
  ) async {
    repo.fetchHold = Completer();
    await _pump(tester, container);
    expect(repo.fetchCalls, isNotEmpty);
    expect(hasSnap(), isFalse);
    expectConn('connecting');
    repo.fetchHold!.complete(Ok([snapRow1()]));
    repo.fetchHold = null;
    await tester.pump();
    await tester.pump();
    expectConn('connected');
  });

  scene('green on all four tabs', (tester) async {
    repo.fetchQueue = [
      [snapRow1()],
    ];
    await _pump(tester, container);
    expect(hasSnap(), isTrue);
    expectConn('connected');
    for (final label in ['Talk', 'Questions', 'Tasks', 'Dashboard']) {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('admin-bottom-bar')),
          matching: find.text(label),
        ),
      );
      await tester.pump();
      await tester.pump();
      expectConn('connected');
    }
  });

  scene('gray when a fetch fails', (tester) async {
    repo.fetchQueue = [
      [snapRow1()],
    ];
    await _pump(tester, container);
    expect(hasSnap(), isTrue);
    expectConn('connected');
    repo.fetchFail = Err(NetworkFailure('x'));
    await nextRound(tester);
    expect(failed(), isTrue);
    expectConn('offline');
  });

  scene('gray when the status call fails', (tester) async {
    repo.fetchQueue = [
      [snapRow1()],
    ];
    await _pump(tester, container);
    expect(hasSnap(), isTrue);
    expectConn('connected');
    repo.statusFail = Err(NetworkFailure('x'));
    await nextRound(tester);
    expect(failed(), isTrue);
    expectConn('offline');
  });

  scene('stays gray while the next round runs after a failure', (tester) async {
    repo.fetchQueue = [
      [snapRow1()],
    ];
    await _pump(tester, container);
    expect(hasSnap(), isTrue);
    expectConn('connected');
    repo.fetchFail = Err(NetworkFailure('x'));
    await nextRound(tester);
    expect(failed(), isTrue);
    expectConn('offline');
    repo.fetchFail = null;
    repo.fetchHold = Completer();
    final callsBefore = repo.fetchCalls.length;
    await nextRound(tester);
    expect(repo.fetchCalls.length, callsBefore + 1);
    expectConn('offline');
    repo.fetchHold!.complete(const Ok(<AdminRow>[]));
    repo.fetchHold = null;
    await tester.pump();
    await tester.pump();
    expectConn('connected');
  });

  scene('gray when the very first round fails', (tester) async {
    repo.fetchFail = Err(NetworkFailure('x'));
    await _pump(tester, container);
    expect(failed(), isTrue);
    expectConn('offline');
  });

  scene('a silent computer does not change the icon', (tester) async {
    repo.fetchQueue = [
      [
        snapRow(1, 1, cursor: 5, items: [dashboardItem]),
      ],
    ];
    await _pump(tester, container);
    expect(hasSnap(), isTrue);
    expectConn('connected');
  });

  // Scene A: after lock and open the icon starts as connecting again
  scene('after lock and open the icon starts as connecting again', (
    tester,
  ) async {
    repo.fetchQueue = [
      [snapRow1()],
    ];
    await _pump(tester, container);
    expectConn('connected');
    final n = container.read(adminPanelsProvider.notifier);
    n.lock();
    await tester.pump();
    repo.fetchHold = Completer();
    unawaited(n.open('r'));
    await tester.pump();
    await tester.pump();
    expect(repo.fetchHold, isNotNull);
    expectConn('connecting');
    repo.fetchHold!.complete(const Ok(<AdminRow>[]));
    repo.fetchHold = null;
    await tester.pump();
    await tester.pump();
    expectConn('connected');
  });

  // Scene B: each state has its colour: green, orange, gray
  scene('each state has its colour: green, orange, gray', (tester) async {
    Color? colorOf(String k) =>
        tester.widget<Icon>(find.byKey(ValueKey('admin-conn-$k'))).color;
    repo.fetchHold = Completer();
    await _pump(tester, container);
    expect(colorOf('connecting'), Colors.orange);
    repo.fetchHold!.complete(Ok([snapRow1()]));
    repo.fetchHold = null;
    await tester.pump();
    await tester.pump();
    expect(colorOf('connected'), Colors.green);
    repo.fetchFail = Err(NetworkFailure('x'));
    await nextRound(tester);
    final off = colorOf('offline');
    expect(off, isNot(Colors.green));
    expect(off, isNot(Colors.orange));
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

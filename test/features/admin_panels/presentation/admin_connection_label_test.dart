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

  /// Helper to advance one poll round.
  Future<void> nextRound(WidgetTester t) async {
    await t.pump(adminPollEvery);
    await t.pump();
    await t.pump();
  }

  /// Snapshot row helper.
  AdminRow snapRow1() => snapRow(1, 1, cursor: 5, items: [qItem('q1')]);

  /// Helper inside main:
  AppLocalizations l10n(WidgetTester t) =>
      AppLocalizations.of(t.element(find.byType(AdminPanelsScreen)));

  void expectLabel(WidgetTester t, String shown) {
    final l = l10n(t);
    for (final s in [
      l.adminConnConnected,
      l.adminConnConnecting,
      l.adminConnOffline,
    ]) {
      expect(
        find.bySemanticsLabel(s),
        s == shown ? findsOneWidget : findsNothing,
        reason: 'label $s',
      );
    }
  }

  scene('each connection state has its own screen-reader label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    repo.fetchHold = Completer();
    await _pump(tester, container);
    expectLabel(tester, l10n(tester).adminConnConnecting);
    repo.fetchHold!.complete(Ok([snapRow1()]));
    repo.fetchHold = null;
    await tester.pump();
    await tester.pump();
    expectLabel(tester, l10n(tester).adminConnConnected);
    repo.fetchFail = Err(NetworkFailure('x'));
    await nextRound(tester);
    expectLabel(tester, l10n(tester).adminConnOffline);
    handle.dispose();
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

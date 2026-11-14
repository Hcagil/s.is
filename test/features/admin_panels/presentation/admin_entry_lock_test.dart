// test/features/admin_panels/presentation/admin_entry_lock_test.dart
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
        home: Scaffold(appBar: AppBar(actions: const [AdminEntryButton()])),
      ),
    ),
  );
  await tester.pump();
}

/// Helper that creates a ProviderContainer with the required overrides and
/// opens the admin panel for room 'r'.
Future<ProviderContainer> scope(WidgetTester tester, Override entry) async {
  final c = ProviderContainer(
    overrides: [
      entry,
      adminPanelsRepositoryProvider.overrideWithValue(
        FakeAdminRepository()
          ..fetchQueue = [
            [
              snapRow(1, 1, items: [qItem('Q-1')]),
            ],
          ],
      ),
      adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
      adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
      adminSeenStoreProvider.overrideWithValue(FakeAdminSeenStore()),
    ],
  );
  addTearDown(c.dispose);
  // Keep adminPanelsProvider alive during the test
  c.listen(adminPanelsProvider, (_, _) {});
  await _pump(tester, c);
  await c.read(adminPanelsProvider.notifier).open('r');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  expect(c.read(adminPanelsProvider).hasSnapshot, isTrue);
  expect(c.read(adminPanelsProvider).snapshot.questions.length, 1);
  return c;
}

void main() {
  const states = [AppLifecycleState.paused, AppLifecycleState.hidden];

  final overrides = {
    'loading': adminEntryProvider.overrideWith(
      (ref) => Completer<bool>().future,
    ),
    'error': adminEntryProvider.overrideWith(
      (ref) async => throw StateError('x'),
    ),
    'off': adminEntryProvider.overrideWith((ref) async => false),
    'owner': adminEntryProvider.overrideWith((ref) async => true),
  };

  for (final caseName in overrides.keys) {
    for (final state in states) {
      testWidgets('$caseName + ${state.toString()} clears the snapshot', (
        tester,
      ) async {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        final c = await scope(tester, overrides[caseName]!);
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(c.read(adminPanelsProvider).hasSnapshot, isFalse);
        expect(c.read(adminPanelsProvider).snapshot.questions.isEmpty, isTrue);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  // Negative tests: owner case should not clear on inactive or resumed.
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    testWidgets('owner + ${state.toString()} does not clear the snapshot', (
      tester,
    ) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final c = await scope(tester, overrides['owner']!);
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect(c.read(adminPanelsProvider).hasSnapshot, isTrue);
      expect(c.read(adminPanelsProvider).snapshot.questions.length, 1);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

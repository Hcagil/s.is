// "Update now" is never silent (iPhone update button), from the contract:
// - the store launch fails (false) -> the notice updateTestFlightOpenFailed
//   shows, on the what's new card and on the blocking screen;
// - it succeeds -> no notice;
// - the TestFlight hint shows under the store-page button on iOS only, never
//   on Android, never under the Play flexible-download button;
// - the widget unmounted before the launch answers -> no notice, no error.
// Real UpdateController over the shared FakeUpdate repository.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/presentation/update_required_screen.dart';
import 'package:sis/features/update/presentation/whats_new_card.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';

const _failed =
    'Could not open TestFlight. Open the TestFlight app and tap Update.';
const _hint = 'The TestFlight app opens. Tap Update next to SIS.';
const _note = 'Version 0.31\n- Chats load faster';

Future<void> _mount(WidgetTester t, FakeUpdate repo, Widget child) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [updateRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child is UpdateRequiredScreen
            ? child
            : Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 10));
  }
}

/// Lets the 2 s notice expire so no timer is left pending.
Future<void> _expire(WidgetTester t) => t.pump(const Duration(seconds: 3));

const _card = WhatsNewCard(body: _note, time: '14:05', isNewest: true);
final _updateNow = find.text('Update now');

void main() {
  group('WhatsNewCard store button', () {
    testWidgets('launch fails -> the failure notice shows', (t) async {
      final repo = FakeUpdate(version: '0.30.17')..storeOpens = false;
      await _mount(t, repo, _card);
      await t.tap(_updateNow);
      await _settle(t);
      expect(repo.calls, ['store']);
      expect(find.text(_failed), findsOneWidget);
      await _expire(t);
    });

    testWidgets('launch succeeds -> no notice', (t) async {
      final repo = FakeUpdate(version: '0.30.17');
      await _mount(t, repo, _card);
      await t.tap(_updateNow);
      await _settle(t);
      expect(repo.calls, ['store']);
      expect(find.text(_failed), findsNothing);
    });

    testWidgets('unmounted before the launch answers: no notice, no error', (
      t,
    ) async {
      final repo = FakeUpdate(version: '0.30.17')
        ..storeOpens = false
        ..storeGate = Completer<void>();
      await _mount(t, repo, _card);
      await t.tap(_updateNow);
      await _settle(t);
      await t.pumpWidget(const SizedBox());
      repo.storeGate!.complete();
      await _settle(t);
      expect(t.takeException(), isNull);
      expect(find.text(_failed), findsNothing);
    });

    testWidgets('iOS: the TestFlight hint shows under the store button', (
      t,
    ) async {
      await _mount(t, FakeUpdate(version: '0.30.17'), _card);
      expect(_updateNow, findsOneWidget);
      expect(find.text(_hint), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Android: no hint', (t) async {
      await _mount(t, FakeUpdate(version: '0.30.17'), _card);
      expect(_updateNow, findsOneWidget);
      expect(find.text(_hint), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('iOS: the Play flexible-download button has no hint', (
      t,
    ) async {
      final repo = FakeUpdate(version: '0.30.17')..offer(108);
      await _mount(t, repo, _card);
      expect(_updateNow, findsOneWidget);
      expect(find.text(_hint), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('UpdateRequiredScreen Update now', () {
    const screen = UpdateRequiredScreen(installed: 1, minimum: 5);

    testWidgets('immediate update fails and the store cannot open -> notice', (
      t,
    ) async {
      final repo = FakeUpdate()
        ..failImmediate = true
        ..storeOpens = false;
      await _mount(t, repo, screen);
      await t.tap(_updateNow);
      await _settle(t);
      expect(repo.calls, ['immediate', 'store']);
      expect(find.text(_failed), findsOneWidget);
      await _expire(t);
    });

    testWidgets('immediate update fails, the store opens -> no notice', (
      t,
    ) async {
      final repo = FakeUpdate()..failImmediate = true;
      await _mount(t, repo, screen);
      await t.tap(_updateNow);
      await _settle(t);
      expect(repo.calls, ['immediate', 'store']);
      expect(find.text(_failed), findsNothing);
    });

    testWidgets('immediate update works -> no store, no notice', (t) async {
      final repo = FakeUpdate()..storeOpens = false;
      await _mount(t, repo, screen);
      await t.tap(_updateNow);
      await _settle(t);
      expect(repo.calls, ['immediate']);
      expect(find.text(_failed), findsNothing);
    });

    testWidgets('unmounted before the answer: no notice, no error', (t) async {
      final repo = FakeUpdate()
        ..failImmediate = true
        ..storeOpens = false
        ..storeGate = Completer<void>();
      await _mount(t, repo, screen);
      await t.tap(_updateNow);
      await _settle(t);
      await t.pumpWidget(const SizedBox());
      repo.storeGate!.complete();
      await _settle(t);
      expect(t.takeException(), isNull);
      expect(find.text(_failed), findsNothing);
    });
  });
}

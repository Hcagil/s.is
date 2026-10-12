// What's new cards in the SIS chat (step 14), from the contract:
// - the card reads the note in the app's language (EN / TR split on '---');
// - "Installed (your version)" marks the card whose version is the one
//   installedVersionProvider reports;
// - only the newest card offers "Update now": when Play offers a flexible
//   update (-> UpdateController.download) or when the card is newer than the
//   installed version (-> UpdateController.openStore);
// - UpdateDownloading: SisProgressLine and "Downloading"; UpdateReadyToInstall:
//   "Restart" -> UpdateController.install; never a forced update;
// - keys whats-new-card-new / whats-new-card-old;
// - UpToDateMark is green and hidden when the newest note is newer than the
//   installed version.
// Two layers: a recording controller for the UI -> controller calls, and the
// real UpdateController over the shared FakeUpdate repository for the seam.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_repository.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:sis/features/update/presentation/whats_new_card.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';

/// Shows a fixed state and records what the card asks of it.
class Recording extends UpdateController {
  Recording(this.shown);
  final UpdateState shown;
  final calls = <String>[];
  @override
  Future<UpdateState> build() async => shown;
  @override
  Future<void> download() async => calls.add('download');
  @override
  Future<void> install() async => calls.add('install');
  @override
  Future<void> openStore() async => calls.add('openStore');
}

const v031 = 'Version 0.31\n- Chats load faster\n• Photos open in place';
const bilingual =
    'Version 0.31\n- Chats load faster\n---\nSürüm 0.31\n- Sohbetler hızlı açılır';
const plain = 'Notifications are grouped now.';

Widget _host(Widget child, List<Override> overrides, Brightness b, Locale l) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: sisTheme(b),
        locale: l,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 10));
  }
}

/// Pumps [child] with a recording controller in [state] and the installed
/// version [installed]; returns the controller.
Future<Recording> pump(
  WidgetTester t,
  UpdateState state,
  Widget child, {
  String installed = '0.30.17',
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) async {
  final c = Recording(state);
  await t.pumpWidget(
    _host(
      child,
      [
        updateControllerProvider.overrideWith(() => c),
        installedVersionProvider.overrideWith(
          (ref) async => (name: installed, build: 100),
        ),
      ],
      brightness,
      locale,
    ),
  );
  await _settle(t);
  return c;
}

Finder byKey(String k) => find.byKey(ValueKey(k));
final updateNow = find.text('Update now');
final installedMark = find.text('Installed (your version)');

WhatsNewCard card(String body, {required bool isNewest}) =>
    WhatsNewCard(body: body, time: '14:05', isNewest: isNewest);

void main() {
  group('WhatsNewCard: language', () {
    testWidgets('English shows the EN part only', (t) async {
      await pump(t, const UpdateIdle(), card(bilingual, isNewest: false));
      expect(find.text('Chats load faster'), findsOneWidget);
      expect(find.textContaining('Sohbetler'), findsNothing);
      expect(find.textContaining('---'), findsNothing);
    });

    testWidgets('Turkish shows the TR part, version line in Turkish', (
      t,
    ) async {
      await pump(
        t,
        const UpdateIdle(),
        card(bilingual, isNewest: false),
        locale: const Locale('tr'),
      );
      expect(find.text('Sohbetler hızlı açılır'), findsOneWidget);
      expect(find.text('Chats load faster'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data?.toLowerCase() == 'sürüm 0.31',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a plain note shows its whole body', (t) async {
      await pump(t, const UpdateIdle(), card(plain, isNewest: true));
      expect(find.text(plain), findsOneWidget);
    });
  });

  group('WhatsNewCard: installed mark', () {
    testWidgets('the card of the installed version says so', (t) async {
      await pump(
        t,
        const UpdateIdle(),
        card(v031, isNewest: false),
        installed: '0.31',
      );
      expect(installedMark, findsOneWidget);
    });

    testWidgets('in Turkish too', (t) async {
      await pump(
        t,
        const UpdateIdle(),
        card(bilingual, isNewest: true),
        installed: '0.31',
        locale: const Locale('tr'),
      );
      expect(find.text('Kurulu (sürümünüz)'), findsOneWidget);
    });

    for (final other in ['0.30.17', '0.31.1', '0.3']) {
      testWidgets('no mark when $other is installed', (t) async {
        await pump(
          t,
          const UpdateIdle(),
          card(v031, isNewest: false),
          installed: other,
        );
        expect(installedMark, findsNothing);
      });
    }
  });

  group('WhatsNewCard: Update now', () {
    testWidgets('newest + flexible update offered -> download', (t) async {
      final c = await pump(
        t,
        const UpdateAvailableFlexible(108),
        card(v031, isNewest: true),
        installed: '0.31',
      );
      expect(updateNow, findsOneWidget);
      await t.tap(updateNow);
      await t.pump();
      expect(c.calls, ['download']);
    });

    testWidgets('newest + newer than installed, nothing offered -> store', (
      t,
    ) async {
      final c = await pump(
        t,
        const UpdateIdle(),
        card(v031, isNewest: true),
        installed: '0.30.17',
      );
      expect(updateNow, findsOneWidget);
      await t.tap(updateNow);
      await t.pump();
      expect(c.calls, ['openStore']);
    });

    for (final installed in ['0.31', '0.31.2']) {
      testWidgets('newest, nothing offered, installed $installed: no button', (
        t,
      ) async {
        await pump(
          t,
          const UpdateIdle(),
          card(v031, isNewest: true),
          installed: installed,
        );
        expect(updateNow, findsNothing);
      });
    }

    for (final s in const <UpdateState>[
      UpdateIdle(),
      UpdateAvailableFlexible(108),
    ]) {
      testWidgets('an older card never offers it (${s.runtimeType})', (
        t,
      ) async {
        await pump(t, s, card(v031, isNewest: false), installed: '0.30.17');
        expect(updateNow, findsNothing);
        expect(find.byType(ButtonStyleButton), findsNothing);
      });
    }

    testWidgets('UpdateDownloading: progress line and Downloading', (t) async {
      await pump(t, const UpdateDownloading(), card(v031, isNewest: true));
      expect(find.byType(SisProgressLine), findsOneWidget);
      expect(find.textContaining('Downloading'), findsOneWidget);
      expect(updateNow, findsNothing);
    });

    testWidgets('UpdateDownloading on an older card shows nothing of it', (
      t,
    ) async {
      await pump(t, const UpdateDownloading(), card(v031, isNewest: false));
      expect(find.byType(SisProgressLine), findsNothing);
      expect(find.textContaining('Downloading'), findsNothing);
    });

    testWidgets('UpdateReadyToInstall: Restart -> install', (t) async {
      final c = await pump(
        t,
        const UpdateReadyToInstall(),
        card(v031, isNewest: true),
      );
      expect(find.text('Restart'), findsOneWidget);
      expect(updateNow, findsNothing);
      await t.tap(find.text('Restart'));
      await t.pump();
      expect(c.calls, ['install']);
    });
  });

  group('WhatsNewCard: keys', () {
    for (final newest in [true, false]) {
      testWidgets('exactly one card key, isNewest $newest', (t) async {
        await pump(t, const UpdateIdle(), card(v031, isNewest: newest));
        final n =
            byKey('whats-new-card-new').evaluate().length +
            byKey('whats-new-card-old').evaluate().length;
        expect(n, 1);
      });
    }

    testWidgets('an older card is whats-new-card-old', (t) async {
      await pump(
        t,
        const UpdateAvailableFlexible(108),
        card(v031, isNewest: false),
      );
      expect(byKey('whats-new-card-old'), findsOneWidget);
      expect(byKey('whats-new-card-new'), findsNothing);
    });
  });

  group('WhatsNewCard: seam with the real UpdateController', () {
    Future<FakeUpdate> mount(
      WidgetTester t,
      FakeUpdate repo,
      String body,
    ) async {
      await t.pumpWidget(
        _host(
          card(body, isNewest: true),
          [updateRepositoryProvider.overrideWithValue(repo)],
          Brightness.light,
          const Locale('en'),
        ),
      );
      await _settle(t);
      return repo;
    }

    testWidgets('a newer note with nothing offered opens the store listing', (
      t,
    ) async {
      final repo = await mount(t, FakeUpdate(version: '0.30.17'), v031);
      expect(installedMark, findsNothing);
      await t.tap(updateNow);
      await _settle(t);
      expect(repo.calls, ['store']);
    });

    testWidgets('the installed version from the repository marks its card', (
      t,
    ) async {
      await mount(t, FakeUpdate(version: '0.31'), v031);
      expect(installedMark, findsOneWidget);
      expect(updateNow, findsNothing);
    });

    testWidgets('an offered flexible update downloads with a progress line, '
        'never the immediate (forced) flow', (t) async {
      final repo = FakeUpdate(version: '0.31')
        ..offer(108)
        ..flexibleGate = Completer<void>();
      await mount(t, repo, v031);
      await t.tap(updateNow);
      await _settle(t);
      expect(repo.calls, ['flexible']);
      expect(find.byType(SisProgressLine), findsOneWidget);
      expect(find.textContaining('Downloading'), findsOneWidget);
      repo.flexibleGate!.complete();
      await _settle(t);
      expect(repo.calls, isNot(contains('immediate')));
    });

    testWidgets('a downloaded update restarts through completeFlexibleUpdate', (
      t,
    ) async {
      final repo = FakeUpdate(version: '0.31')
        ..play = const Ok(PlayUpdateCheck(offeredBuild: 108, downloaded: true));
      await mount(t, repo, v031);
      await t.tap(find.text('Restart'));
      await _settle(t);
      expect(repo.calls, ['complete']);
    });
  });

  group('WhatsNewCard: layout', () {
    final long =
        'Version 10.100.1000\n'
        '${List.generate(6, (i) => '- ${'Averyveryverylongunbrokenword' * 3} item $i and more words that wrap').join('\n')}';
    for (final b in Brightness.values) {
      testWidgets(
        'renders at 360 wide without overflow, ${b.name}',
        (t) async {
          t.view.physicalSize = const Size(360, 800);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          for (final s in const <UpdateState>[
            UpdateAvailableFlexible(108),
            UpdateDownloading(),
            UpdateReadyToInstall(),
          ]) {
            for (final body in [long, v031, bilingual, plain * 8]) {
              for (final newest in [true, false]) {
                await pump(
                  t,
                  s,
                  card(body, isNewest: newest),
                  installed: '0.31',
                  brightness: b,
                );
                expect(t.takeException(), isNull);
                expect(find.byType(WhatsNewCard), findsOneWidget);
              }
            }
          }
        },
        variant: TargetPlatformVariant(const {
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }
  });

  group('UpToDateMark', () {
    Color? markColor(WidgetTester t) {
      final text = t.widget<Text>(
        find.descendant(
          of: byKey('whats-new-up-to-date'),
          matching: find.text("You're up to date"),
        ),
      );
      return text.style?.color ??
          DefaultTextStyle.of(t.element(find.text("You're up to date")))
              .style
              .color;
    }

    for (final installed in ['0.31', '0.31.1', '0.40']) {
      testWidgets('shown, green, when $installed is installed and 0.31 is '
          'the newest note', (t) async {
        await pump(
          t,
          const UpdateIdle(),
          const UpToDateMark(newestBody: v031),
          installed: installed,
        );
        expect(byKey('whats-new-up-to-date'), findsOneWidget);
        expect(find.text("You're up to date"), findsOneWidget);
        final c = markColor(t)!;
        expect(
          c.g > c.r && c.g > c.b,
          isTrue,
          reason: 'green expected, got $c',
        );
      });
    }

    testWidgets('Turkish', (t) async {
      await pump(
        t,
        const UpdateIdle(),
        const UpToDateMark(newestBody: v031),
        installed: '0.31',
        locale: const Locale('tr'),
      );
      expect(find.text('Güncelsiniz'), findsOneWidget);
    });

    for (final installed in ['0.30.17', '0.30', '0.3']) {
      testWidgets('hidden when the newest note 0.31 is newer than $installed', (
        t,
      ) async {
        await pump(
          t,
          const UpdateIdle(),
          const UpToDateMark(newestBody: v031),
          installed: installed,
        );
        expect(byKey('whats-new-up-to-date'), findsNothing);
        expect(find.text("You're up to date"), findsNothing);
      });
    }
  });
}

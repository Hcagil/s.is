// What's new cards in the SIS chat, from the contract: a structured note on
// the newest card is lit (whats-new-card-new) only while an update is
// available, downloading or ready; every other structured card is dimmed
// (whats-new-card-old); a plain note shows its body; no "Update now" button.
// UpToDateMark (whats-new-up-to-date) speaks only when the state is idle.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:sis/features/update/presentation/whats_new_card.dart';
import 'package:sis/l10n/app_localizations.dart';

class _Showing extends UpdateController {
  _Showing(this.shown);
  final UpdateState shown;
  @override
  Future<UpdateState> build() async => shown;
}

const versioned = 'v0.31\n- Chats load faster\n• Photos open in place';
const plain = 'Notifications are grouped now.';

Future<void> pump(
  WidgetTester t,
  UpdateState state,
  Widget child, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [updateControllerProvider.overrideWith(() => _Showing(state))],
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

Finder byKey(String k) => find.byKey(ValueKey(k));

/// A Text reading [s], in any letter case (the design may set it in caps).
Finder saying(String s) => find.byWidgetPredicate(
  (w) => w is Text && w.data?.toLowerCase() == s.toLowerCase(),
);

WhatsNewCard card(String body, {required bool isNewest}) =>
    WhatsNewCard(body: body, time: '14:05', isNewest: isNewest);

const offered = <UpdateState>[
  UpdateAvailableFlexible(108),
  UpdateDownloading(),
  UpdateReadyToInstall(),
];

void main() {
  group('WhatsNewCard', () {
    for (final s in offered) {
      testWidgets('newest structured card is lit while ${s.runtimeType}', (
        t,
      ) async {
        await pump(t, s, card(versioned, isNewest: true));
        expect(byKey('whats-new-card-new'), findsOneWidget);
        expect(byKey('whats-new-card-old'), findsNothing);
        expect(find.textContaining('0.31'), findsOneWidget);
        expect(find.textContaining('Chats load faster'), findsOneWidget);
        expect(find.textContaining('Photos open in place'), findsOneWidget);
      });

      testWidgets('an older structured card is dimmed while ${s.runtimeType}', (
        t,
      ) async {
        await pump(t, s, card(versioned, isNewest: false));
        expect(byKey('whats-new-card-old'), findsOneWidget);
        expect(byKey('whats-new-card-new'), findsNothing);
      });
    }

    for (final s in const <UpdateState>[
      UpdateIdle(),
      UpdateRequired(installed: 100, minimum: 105),
    ]) {
      testWidgets('the newest card is dimmed when ${s.runtimeType}', (t) async {
        await pump(t, s, card(versioned, isNewest: true));
        expect(byKey('whats-new-card-old'), findsOneWidget);
        expect(byKey('whats-new-card-new'), findsNothing);
      });
    }

    testWidgets('the version reads through l10n in English and Turkish', (
      t,
    ) async {
      await pump(t, const UpdateIdle(), card(versioned, isNewest: true));
      expect(saying('Version 0.31'), findsOneWidget);
      await pump(
        t,
        const UpdateIdle(),
        card(versioned, isNewest: true),
        locale: const Locale('tr'),
      );
      expect(saying('Sürüm 0.31'), findsOneWidget);
    });

    for (final s in [const UpdateIdle(), ...offered]) {
      testWidgets('a plain note shows its body and no version line, '
          'when ${s.runtimeType}', (t) async {
        await pump(t, s, card(plain, isNewest: true));
        expect(find.text(plain), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Text && (w.data ?? '').toLowerCase().startsWith('version'),
          ),
          findsNothing,
        );
      });
    }

    testWidgets('no "Update now" button, lit or not', (t) async {
      for (final newest in [true, false]) {
        await pump(
          t,
          const UpdateAvailableFlexible(108),
          card(versioned, isNewest: newest),
        );
        expect(find.textContaining('Update now'), findsNothing);
        expect(find.byType(ButtonStyleButton), findsNothing);
        expect(find.byType(IconButton), findsNothing);
      }
    });

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
          for (final body in [long, versioned, plain * 8]) {
            for (final newest in [true, false]) {
              await pump(
                t,
                const UpdateDownloading(),
                card(body, isNewest: newest),
                brightness: b,
              );
              expect(t.takeException(), isNull);
              expect(find.byType(WhatsNewCard), findsOneWidget);
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
    testWidgets('idle: says you are up to date, in English and Turkish', (
      t,
    ) async {
      await pump(t, const UpdateIdle(), const UpToDateMark());
      expect(byKey('whats-new-up-to-date'), findsOneWidget);
      expect(find.text("You're up to date"), findsOneWidget);

      await pump(
        t,
        const UpdateIdle(),
        const UpToDateMark(),
        locale: const Locale('tr'),
      );
      expect(find.text('Güncelsiniz'), findsOneWidget);
    });

    for (final s in [
      ...offered,
      const UpdateRequired(installed: 100, minimum: 105),
    ]) {
      testWidgets('${s.runtimeType}: shows nothing', (t) async {
        await pump(t, s, const UpToDateMark());
        expect(byKey('whats-new-up-to-date'), findsNothing);
        expect(find.text("You're up to date"), findsNothing);
      });
    }
  });
}

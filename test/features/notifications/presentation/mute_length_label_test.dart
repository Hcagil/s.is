// muteLengthLabel and the profile MuteTile in English and Turkish (Update 1
// slice 4): the five lengths, no "Always" in any picker, Unmute localised.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/notifications/presentation/notification_pages.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../../support/fakes.dart';

const en = {
  MuteLength.oneHour: '1 hour',
  MuteLength.eightHours: '8 hours',
  MuteLength.oneDay: '1 day',
  MuteLength.threeDays: '3 days',
  MuteLength.oneWeek: '1 week',
};
const tr = {
  MuteLength.oneHour: '1 saat',
  MuteLength.eightHours: '8 saat',
  MuteLength.oneDay: '1 gün',
  MuteLength.threeDays: '3 gün',
  MuteLength.oneWeek: '1 hafta',
};

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<void> pumpTile(WidgetTester t, Locale locale, {bool muted = false}) =>
    t.pumpWidget(
      ProviderScope(
        overrides: [
          notificationSettingsRepositoryProvider.overrideWithValue(
            NotificationSettingsFake(
              mutes: [
                if (muted)
                  Mute(
                    kind: MuteKind.person,
                    target: 'ub',
                    until: DateTime.now().add(const Duration(hours: 3)),
                  ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: MuteTile(kind: MuteKind.person, target: 'ub'),
          ),
        ),
      ),
    );

void main() {
  test('muteLengthLabel: every length in English and Turkish', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final k = lookupAppLocalizations(const Locale('tr'));
    expect(MuteLength.values.toSet(), en.keys.toSet());
    for (final m in MuteLength.values) {
      expect(muteLengthLabel(l, m), en[m], reason: 'en ${m.name}');
      expect(muteLengthLabel(k, m), tr[m], reason: 'tr ${m.name}');
    }
  });

  test('the new chat-list strings exist in both languages', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final k = lookupAppLocalizations(const Locale('tr'));
    expect(
      [l.chatMenuMute, l.chatMenuUnmute, l.chatMenuPin, l.chatArchive],
      ['Mute', 'Unmute', 'Pin chat', 'Archive'],
    );
    expect(l.chatMutedLabel, 'Muted');
    expect(
      [k.chatMenuMute, k.chatMenuUnmute, k.chatMenuPin, k.chatArchive],
      ['Sessize al', 'Sesi aç', 'Sohbeti sabitle', 'Arşivle'],
    );
    expect(k.chatMutedLabel, 'Sessiz');
  });

  for (final (locale, labels, unmute) in [
    (const Locale('en'), en, 'Unmute'),
    (const Locale('tr'), tr, 'Sesi aç'),
  ]) {
    testWidgets('${locale.languageCode}: the profile mute card lists the five '
        'lengths by name and label, no Always, no Unmute when not muted', (
      t,
    ) async {
      await pumpTile(t, locale);
      await t.pumpAndSettle();
      await t.tap(byKey('mute-tile'));
      await t.pumpAndSettle();
      expect(byKey('mute-card'), findsOneWidget);
      for (final m in MuteLength.values) {
        expect(
          find.descendant(
            of: byKey('mute-${m.name}'),
            matching: find.text(labels[m]!),
          ),
          findsOneWidget,
          reason: m.name,
        );
      }
      expect(byKey('mute-always'), findsNothing);
      expect(find.text('Always'), findsNothing);
      expect(byKey('mute-off'), findsNothing);
    });

    testWidgets('${locale.languageCode}: muted, the card offers "$unmute"', (
      t,
    ) async {
      await pumpTile(t, locale, muted: true);
      await t.pumpAndSettle();
      await t.tap(byKey('mute-tile'));
      await t.pumpAndSettle();
      expect(
        find.descendant(of: byKey('mute-off'), matching: find.text(unmute)),
        findsOneWidget,
      );
    });
  }
}

// Slice 7a, from its contract: Settings > Media auto-download (WhatsApp's
// page): the three presets, the per-network rows with their Photos / Audio /
// Videos / Documents check list, OK and Cancel. Each change shows at once and
// is saved. Written from the contract, never from the widgets.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/autodownload/application/auto_download_controller.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';
import 'package:sis/features/autodownload/presentation/auto_download_page.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/file_fakes.dart';
import '../profile/settings_pages_test.dart' show overrides, maya;

Finder byKey(String k) => find.byKey(ValueKey(k));

Widget app(Widget home, List overridesList) => ProviderScope(
  overrides: [...overridesList],
  child: MaterialApp(
    theme: sisTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  late AutoDownloadStoreFake store;

  Future<AutoDownloadSettings Function()> page(
    WidgetTester t, {
    AutoDownloadSettings initial = const AutoDownloadSettings(),
  }) async {
    store = AutoDownloadStoreFake(initial);
    final container = ProviderContainer.test(
      overrides: [
        autoDownloadStoreProvider.overrideWithValue(store),
        initialAutoDownloadProvider.overrideWithValue(initial),
      ],
    );
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AutoDownloadPage(),
        ),
      ),
    );
    await t.pumpAndSettle();
    return () => container.read(autoDownloadProvider);
  }

  testWidgets('Settings has the Media auto-download row, and it opens the '
      'page', (t) async {
    await t.pumpWidget(
      app(const SettingsScreen(), [
        ...overrides(profile: ProfileFake(profile: maya)),
        autoDownloadStoreProvider.overrideWithValue(AutoDownloadStoreFake()),
      ]),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(byKey('settings-auto-download'), 200);
    await t.tap(byKey('settings-auto-download'));
    await t.pumpAndSettle();
    expect(find.byType(AutoDownloadPage), findsOneWidget);
    for (final k in [
      'autodl-enable',
      'autodl-wifionly',
      'autodl-disabled',
      'autodl-row-mobile',
      'autodl-row-wifi',
      'autodl-row-roaming',
    ]) {
      expect(byKey(k), findsOneWidget, reason: k);
    }
  });

  for (final (key, preset) in [
    ('autodl-disabled', AutoDownloadPreset.disabled),
    ('autodl-enable', AutoDownloadPreset.enable),
    ('autodl-wifionly', AutoDownloadPreset.wifiOnly),
  ]) {
    testWidgets('$key applies the ${preset.name} preset and saves it', (
      t,
    ) async {
      final start = preset == AutoDownloadPreset.disabled
          ? const AutoDownloadSettings()
          : AutoDownloadSettings.forPreset(AutoDownloadPreset.disabled);
      final now = await page(t, initial: start);
      await t.tap(byKey(key));
      await t.pumpAndSettle();
      expect(now(), AutoDownloadSettings.forPreset(preset));
      expect(now().preset, preset);
      expect(store.saved.last, AutoDownloadSettings.forPreset(preset));
    });
  }

  testWidgets('a network row lists the four kinds; OK keeps the change', (
    t,
  ) async {
    final now = await page(t);
    await t.tap(byKey('autodl-row-mobile'));
    await t.pumpAndSettle();
    for (final k in MediaKind.values) {
      expect(byKey('autodl-kind-${k.name}'), findsOneWidget, reason: k.name);
    }
    await t.tap(byKey('autodl-kind-documents'));
    await t.pumpAndSettle();
    await t.tap(byKey('autodl-ok'));
    await t.pumpAndSettle();
    expect(now().kindsFor(NetworkKind.mobile), {
      MediaKind.photos,
      MediaKind.documents,
    });
    expect(now().kindsFor(NetworkKind.wifi), MediaKind.values.toSet());
    expect(now().preset, isNull, reason: 'a custom mix is no preset');
    expect(store.saved.last, now());
    expect(byKey('autodl-ok'), findsNothing, reason: 'the list closed');
  });

  testWidgets('Cancel drops the change and saves nothing', (t) async {
    final now = await page(t);
    await t.tap(byKey('autodl-row-wifi'));
    await t.pumpAndSettle();
    await t.tap(byKey('autodl-kind-photos'));
    await t.pumpAndSettle();
    await t.tap(byKey('autodl-cancel'));
    await t.pumpAndSettle();
    expect(now(), const AutoDownloadSettings());
    expect(store.saved, isEmpty);
    expect(byKey('autodl-cancel'), findsNothing);
  });

  testWidgets('unticking a kind on roaming-all removes only that kind', (
    t,
  ) async {
    final now = await page(
      t,
      initial: AutoDownloadSettings.forPreset(AutoDownloadPreset.enable),
    );
    await t.tap(byKey('autodl-row-roaming'));
    await t.pumpAndSettle();
    await t.tap(byKey('autodl-kind-videos'));
    await t.pumpAndSettle();
    await t.tap(byKey('autodl-ok'));
    await t.pumpAndSettle();
    expect(now().kindsFor(NetworkKind.roaming), {
      MediaKind.photos,
      MediaKind.audio,
      MediaKind.documents,
    });
  });
}

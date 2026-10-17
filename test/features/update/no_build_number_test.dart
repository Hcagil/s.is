// The build number (versionCode = run_number + 100) never shows in the app,
// from the contract (2026-10-16): not on the update-required screen, not in
// the update banner, not on the newest What's new card's update prompt.
// Every build here (316, 318, 320) is a number no version name contains.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:sis/features/update/presentation/update_banner.dart';
import 'package:sis/features/update/presentation/update_required_screen.dart';
import 'package:sis/features/update/presentation/whats_new_card.dart';

import '../../support/l10n.dart';

class _Showing extends UpdateController {
  _Showing(this.shown);
  final UpdateState shown;
  @override
  Future<UpdateState> build() async => shown;
}

Future<void> _pump(
  WidgetTester t,
  UpdateState state,
  Widget child, {
  Locale locale = const Locale('en'),
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        updateControllerProvider.overrideWith(() => _Showing(state)),
        installedVersionProvider.overrideWith(
          (ref) async => (name: '26.10.220', build: 316),
        ),
      ],
      child: localizedApp(
        locale: locale,
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 10));
  }
}

void _noBuild(List<String> builds) {
  for (final b in builds) {
    expect(find.textContaining(b), findsNothing, reason: 'build $b shows');
  }
}

void main() {
  for (final l in const [Locale('en'), Locale('tr')]) {
    testWidgets('update-required screen (${l.languageCode}): no build', (
      t,
    ) async {
      await _pump(
        t,
        const UpdateRequired(installed: 316, minimum: 320),
        const SizedBox(
          height: 800,
          child: UpdateRequiredScreen(installed: 316, minimum: 320),
        ),
        locale: l,
      );
      expect(find.byType(UpdateRequiredScreen), findsOneWidget);
      _noBuild(['316', '320']);
    });

    testWidgets('update banner (${l.languageCode}): no build', (t) async {
      for (final s in const <UpdateState>[
        UpdateAvailableFlexible(318),
        UpdateDownloading(),
        UpdateReadyToInstall(),
      ]) {
        await _pump(t, s, const UpdateBanner(), locale: l);
        _noBuild(['318', '316']);
      }
    });

    testWidgets("What's new prompt (${l.languageCode}): no build", (t) async {
      await _pump(
        t,
        const UpdateAvailableFlexible(318),
        const WhatsNewCard(
          body: 'Version 26.10.221 (318)\n- a\n---\nSürüm 26.10.221 (318)\n- b',
          time: '14:05',
          isNewest: true,
        ),
        locale: l,
      );
      _noBuild(['318', '316']);
    });
  }
}

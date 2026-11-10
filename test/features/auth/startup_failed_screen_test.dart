// test/features/auth/startup_failed_screen_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/startup_failure.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';

import '../../support/l10n.dart';

void main() {
  final enBody = l10nEn.statusStartBody(l10nEn.statusStartBootstrap);
  final trBody = l10nTr.statusStartBody(l10nTr.statusStartBootstrap);

  testWidgets('StartupFailedScreen shows correct body in English', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: const StartupFailedScreen(StartupFailure.bootstrap),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(enBody), findsOneWidget);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data?.toLowerCase() ?? '')
        .toList();
    expect(
      texts.where(
        (s) =>
            s.contains('reinstall') || s.contains('kaldırıp tekrar yükleyin'),
      ),
      isEmpty,
    );
  });

  testWidgets('StartupFailedScreen shows correct body in Turkish', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: const StartupFailedScreen(StartupFailure.bootstrap),
        locale: const Locale('tr'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(trBody), findsOneWidget);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data?.toLowerCase() ?? '')
        .toList();
    expect(
      texts.where(
        (s) =>
            s.contains('reinstall') || s.contains('kaldırıp tekrar yükleyin'),
      ),
      isEmpty,
    );
  });
}

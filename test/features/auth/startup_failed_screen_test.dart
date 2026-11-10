// test/features/auth/startup_failed_screen_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/startup_failure.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';

import '../../support/l10n.dart';

void main() {
  const enBody =
      'Restart the app. If it keeps failing, please try again later.\n\nSIS could not start. Please try again.';
  const trBody =
      'Uygulamayı yeniden başlatın. Yine olmazsa lütfen daha sonra tekrar deneyin.\n\nSIS başlatılamadı. Tekrar deneyin.';

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

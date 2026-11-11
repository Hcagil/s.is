import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';

import '../../support/l10n.dart';

void main() {
  testWidgets('removed screen shows correct texts in English', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(home: const StatusScreen.removed(onSignOut: _noop)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10nEn.removedTitle), findsOneWidget);
    expect(find.text(l10nEn.removedBody), findsOneWidget);
    expect(find.text(l10nEn.settingsSignOut), findsOneWidget);

    expect(find.text(l10nEn.replacedTitle), findsNothing);
    expect(find.text(l10nEn.replacedBody), findsNothing);
  });

  testWidgets('removed screen shows correct texts in Turkish', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        locale: const Locale('tr'),
        home: const StatusScreen.removed(onSignOut: _noop),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10nTr.removedTitle), findsOneWidget);
    expect(find.text(l10nTr.removedBody), findsOneWidget);
    expect(find.text(l10nTr.settingsSignOut), findsOneWidget);

    expect(find.text(l10nTr.replacedTitle), findsNothing);
    expect(find.text(l10nTr.replacedBody), findsNothing);
  });

  testWidgets('tapping sign out button calls onSignOut once', (
    WidgetTester tester,
  ) async {
    var calls = 0;
    Future<void> onSignOut() async {
      calls++;
    }

    await tester.pumpWidget(
      localizedApp(home: StatusScreen.removed(onSignOut: onSignOut)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10nEn.settingsSignOut));
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('replaced screen shows replaced texts and not removed texts', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(home: const StatusScreen.replaced(onSignIn: _noop)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10nEn.replacedTitle), findsOneWidget);
    expect(find.text(l10nEn.replacedBody), findsOneWidget);

    expect(find.text(l10nEn.removedTitle), findsNothing);
    expect(find.text(l10nEn.removedBody), findsNothing);
  });
}

Future<void> _noop() async {}

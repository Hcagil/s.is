import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/main.dart';
import 'package:sis/session_controller.dart';

void main() {
  testWidgets('missing runtime configuration shows setup-required state', (
    tester,
  ) async {
    await tester.pumpWidget(
      SisApp(controller: SessionController.unconfigured()),
    );

    expect(find.text('Setup required'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}

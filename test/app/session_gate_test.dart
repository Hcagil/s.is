import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Widget app(FakeAuth a, FakeUpdate u) => ProviderScope(
  overrides: [
    runtimeConfigProvider.overrideWithValue(config),
    authRepositoryProvider.overrideWithValue(a),
    updateRepositoryProvider.overrideWithValue(u),
  ],
  child: const SisApp(),
);

void main() {
  testWidgets('signed out shows button and the last failure reason', (t) async {
    final a = FakeAuth(
      signInResult: const Err(
        ProviderFailure('Google sign-in canceled: console', userCanceled: true),
      ),
    );
    await t.pumpWidget(app(a, FakeUpdate()));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.textContaining('console'), findsOneWidget);
  });
  testWidgets('denied', (t) async {
    await t.pumpWidget(
      app(FakeAuth(session: true, allowed: false), FakeUpdate()),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('not currently approved'), findsOneWidget);
  });
  testWidgets('allowed shows greeting', (t) async {
    await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate()));
    await t.pumpAndSettle();
    expect(find.text('Welcome, Maya'), findsOneWidget);
  });
  testWidgets('update required hides the app', (t) async {
    await t.pumpWidget(
      app(FakeAuth(session: true), FakeUpdate(min: const Ok(999))),
    );
    await t.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    expect(find.text('Welcome, Maya'), findsNothing);
  });
  testWidgets('flexible update shows a dismissible banner', (t) async {
    await t.pumpWidget(
      app(FakeAuth(session: true), FakeUpdate(play: const Ok(107))),
    );
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    await t.tap(find.text('Later'));
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
  });
  testWidgets('error shows reason and retry', (t) async {
    final a = FakeAuth(
      signInResult: const Err(
        ProviderFailure('Supabase rejected the Google token: boom'),
      ),
    );
    await t.pumpWidget(app(a, FakeUpdate()));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('incomplete config shows setup required without any backend', (
    t,
  ) async {
    await t.pumpWidget(const ProviderScope(overrides: [], child: SisApp()));
    await t.pumpAndSettle();
    expect(find.text('Setup required'), findsOneWidget);
  });

  testWidgets('finished download shows restart', (t) async {
    await t.pumpWidget(
      app(FakeAuth(session: true), FakeUpdate(play: const Ok(107))),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Update'));
    await t.pumpAndSettle();
    expect(find.text('Ready to install'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
  });
}

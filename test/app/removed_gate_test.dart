import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/l10n.dart';
import '../support/last_session_fakes.dart';
import '../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Widget app(FakeAuth a, FakeUpdate u, {required MemoryLastSessionStore store}) =>
    ProviderScope(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(a),
        updateRepositoryProvider.overrideWithValue(u),
        chatRepositoryProvider.overrideWithValue(FakeChat()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(ProfileFake()),
        lastSessionStoreProvider.overrideWithValue(store),
      ],
      child: const SisApp(),
    );

void main() {
  testWidgets('removed screen shown when marker stored', (t) async {
    final a = CheckingAuth(session: true)
      ..answer = const Err(NotAllowedFailure());
    final store = MemoryLastSessionStore(marker());
    await t.pumpWidget(app(a, FakeUpdate(), store: store));
    await t.pumpAndSettle();
    expect(find.textContaining(l10nEn.removedTitle), findsOneWidget);
    expect(find.textContaining(l10nEn.removedBody), findsOneWidget);
    expect(find.textContaining(l10nEn.statusDeniedBody), findsNothing);
    expect(find.textContaining(l10nEn.replacedTitle), findsNothing);
    expect(find.textContaining(l10nEn.replacedBody), findsNothing);
  });

  testWidgets('denied screen shown when no marker', (t) async {
    final a = CheckingAuth(session: true)
      ..answer = const Err(NotAllowedFailure());
    final store = MemoryLastSessionStore();
    await t.pumpWidget(app(a, FakeUpdate(), store: store));
    await t.pumpAndSettle();
    expect(find.textContaining(l10nEn.statusDeniedBody), findsOneWidget);
    expect(find.textContaining(l10nEn.removedTitle), findsNothing);
  });

  testWidgets('sign out from removed screen works', (t) async {
    final a = CheckingAuth(session: true)
      ..answer = const Err(NotAllowedFailure());
    final store = MemoryLastSessionStore(marker());
    await t.pumpWidget(app(a, FakeUpdate(), store: store));
    await t.pumpAndSettle();
    await t.tap(find.text(l10nEn.settingsSignOut));
    await t.pumpAndSettle();
    expect(a.signOuts, 1);
  });
}

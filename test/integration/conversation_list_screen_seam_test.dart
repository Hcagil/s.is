@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/dead_host.dart';

/// The home screen wired exactly as `main.dart` wires it, over a real
/// [SupabaseChatRepository] pointed at a server that will never answer.
///
/// The provider- and repository-level tests prove that a broken connection
/// becomes a readable [Failure]; they cannot prove that the *screen*, wired
/// the way production wires it, ever puts that message in front of a member
/// instead of a raw exception rendered by `error.toString()` somewhere on
/// the way up.
///
/// Google sign-in and the Play in-app-update API have nothing to run against
/// locally (docs/ARCHITECTURE.md), so auth and update stay fakes; profile and
/// presence are real, reachable clients so the session gate and onboarding
/// check settle on the home screen. Only chat is offline.
///
/// Requires `docker compose run --rm supabase start`. Reuses cleo
/// (supabase/seed.sql, also used by auth_member_integration_test.dart);
/// run with --concurrency=1 like the rest of the suite.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client(String url) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_url);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

void main() {
  // Real timers, not the fake clock `TestWidgetsFlutterBinding.
  // ensureInitialized()` installs: the failure path exercised here relies
  // on a Realtime channel's own reconnect timer actually firing on a dead
  // host, which a fake clock never advances on its own.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets(
    'a member with no connection sees the offline message, never raw SDK '
    'text, on the real conversation list',
    (t) async {
      final live = (await t.runAsync(
        () => _signedIn('cleo@integration.test'),
      ))!;
      addTearDown(() => live.dispose());
      // The screen must reach home: onboarding is done for this member.
      await t.runAsync(
        () => live
            .from('profiles')
            .update({'onboarding_done': true})
            .eq('user_id', live.auth.currentUser!.id),
      );
      final dead = (await t.runAsync(() => deadButSignedIn(live)))!;
      addTearDown(() => dead.dispose());

      final container = ProviderContainer(
        overrides: [
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: _url,
              supabasePublishableKey: _key,
              googleWebClientId: 'c',
            ),
          ),
          authRepositoryProvider.overrideWithValue(
            FakeAuth(
              session: true,
              member: Member(
                userId: live.auth.currentUser!.id,
                displayName: 'Cleo',
              ),
            ),
          ),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          // The one connection under test: chat, over a real repository
          // pointed at a server that will never answer.
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(dead),
          ),
          // Reachable, so the gate settles on home rather than an error
          // of its own.
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(live),
          ),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(live),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(conversationListProvider, (_, _) {});

      await t.pumpWidget(
        UncontrolledProviderScope(container: container, child: const SisApp()),
      );

      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await t.pump();
        if (find.text(offlineMessage).evaluate().isNotEmpty) break;
      }

      expect(
        find.text(offlineMessage),
        findsOneWidget,
        reason: 'the conversation list never showed the offline message',
      );
      for (final needle in [
        'Exception',
        'statusCode',
        'errno',
        'Failed host lookup',
      ]) {
        expect(
          find.textContaining(needle),
          findsNothing,
          reason: 'raw SDK text reached the screen',
        );
      }
    },
  );
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/data/supabase_account_deletion_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/account_deletion_controller.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/account_deletion_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const maya = OwnProfile(
  userId: 'u1',
  displayName: 'Maya Profile',
  tag: 'maya',
  onboardingDone: true,
);

const mayaAccount = Member(
  userId: 'u1',
  displayName: 'Maya Google',
  email: 'maya.k@example.org',
);

/// Helper that creates a [SupabaseClient] backed by a [MockClient].
SupabaseClient clientWith(int status, String body) {
  final mock = MockClient((request) async {
    return http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  });
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: mock,
  );
}

List<Override> overrides({
  FakeAuth? auth,
  FakeUpdate? update,
  ProfileFake? profile,
  PushRegistryFake? push,
  AttachmentCacheFake? photos,
}) => [
  ...videoOverrides(),
  runtimeConfigProvider.overrideWithValue(config),
  authRepositoryProvider.overrideWithValue(
    auth ?? FakeAuth(session: true, member: mayaAccount),
  ),
  updateRepositoryProvider.overrideWithValue(update ?? FakeUpdate()),
  chatRepositoryProvider.overrideWithValue(FakeChat()),
  presenceRepositoryProvider.overrideWithValue(PresenceFake()),
  profileRepositoryProvider.overrideWithValue(
    profile ?? ProfileFake(profile: maya),
  ),
  pushSourceProvider.overrideWithValue(PushSourceFake()),
  pushRegistryProvider.overrideWithValue(push ?? PushRegistryFake()),
  attachmentCacheProvider.overrideWithValue(photos ?? AttachmentCacheFake()),
];

Future<void> openPage(WidgetTester t, String row) async {
  await openSettings(t);
  await t.tap(byKey(row));
  await t.pumpAndSettle();
}

Future<void> openSettings(WidgetTester t) async {
  await t.tap(byKey('home-settings'));
  await t.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

Finder byKey(String k) => find.byKey(ValueKey(k));

void main() {
  group('unreadable server answer', () {
    test('requestDeletion must not throw on unreadable answer', () async {
      final repo = SupabaseAccountDeletionRepository(
        clientWith(200, jsonEncode('not-a-date')),
        FakeAuth(),
      );
      Result<DateTime>? r;
      Object? thrown;
      try {
        r = await repo.requestDeletion();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNull, reason: 'requestDeletion must never throw');
      expect(r, isNotNull);
    });

    testWidgets('sign out after server returns unreadable answer',
        (t) async {
      final auth = FakeAuth(session: true, member: mayaAccount);
      final repo = SupabaseAccountDeletionRepository(
        clientWith(200, jsonEncode('not-a-date')),
        FakeAuth(),
      );
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(auth: auth),
            accountDeletionRepositoryProvider.overrideWithValue(repo),
          ],
          child: const SisApp(),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      await openPage(t, 'settings-account');
      await t.ensureVisible(byKey('account-delete'));
      await t.tap(byKey('account-delete'));
      await t.pumpAndSettle();
      await t.tap(byKey('account-delete-confirm'));
      await t.pumpAndSettle();

      expect(auth.signOuts, 1,
          reason: 'the request is on the server, so the phone must sign out');
    });
  });
}

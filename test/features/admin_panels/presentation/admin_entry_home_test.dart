// test/features/admin_panels/presentation/admin_entry_home_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../../support/fakes.dart';
import '../../../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Future<void> pumpApp(WidgetTester t, FakeAdminRepository repo) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(FakeChat()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(
          ProfileFake(
            profile: const OwnProfile(
              userId: 'u1',
              displayName: 'Maya Profile',
              tag: 'maya',
              onboardingDone: true,
            ),
          ),
        ),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
        adminSnapshotStoreProvider.overrideWithValue(FakeAdminSnapshotStore()),
        adminSeenStoreProvider.overrideWithValue(FakeAdminSeenStore()),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

void main() {
  testWidgets('owner: home-admin is left of home-settings', (t) async {
    final repo = FakeAdminRepository();
    await pumpApp(t, repo);

    final admin = find.byKey(const ValueKey('home-admin'));
    final settings = find.byKey(const ValueKey('home-settings'));
    expect(admin, findsOneWidget);
    expect(settings, findsOneWidget);
    expect(
      t.getCenter(admin).dx < t.getCenter(settings).dx,
      isTrue,
      reason: 'admin button not left of settings',
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('owner: tapping home-admin opens Admin Panels', (t) async {
    final repo = FakeAdminRepository();
    await pumpApp(t, repo);

    final admin = find.byKey(const ValueKey('home-admin'));
    await t.tap(admin);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(AdminPanelsScreen), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('not the owner: nothing is drawn', (t) async {
    final repo = FakeAdminRepository();
    repo.statusResult = const Ok<AdminStatus?>(null);
    await pumpApp(t, repo);

    expect(find.byKey(const ValueKey('home-admin')), findsNothing);
    expect(find.byKey(const ValueKey('home-settings')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Settings has no Admin Panels row', (t) async {
    final repo = FakeAdminRepository();
    await pumpApp(t, repo);

    final settings = find.byKey(const ValueKey('home-settings'));
    await t.tap(settings);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-admin')), findsNothing);
    expect(find.byKey(const ValueKey('settings-profile')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('signing out wipes the admin data (wired in SisApp)', (t) async {
    final repo = FakeAdminRepository();
    await pumpApp(t, repo);
    expect(repo.forgetCalls, 0);

    // Navigate to Settings > Account > Sign out
    await t.tap(find.byKey(const ValueKey('home-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('settings-account')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('account-sign-out')));
    await t.pumpAndSettle();

    expect(repo.forgetCalls, 1);
    await t.pumpWidget(const SizedBox());
  });
}

// test/features/admin_panels/presentation/admin_entry_badge_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/presentation/admin_panels_screen.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../../support/fakes.dart';
import '../../../support/video_fakes.dart';

import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/presentation/admin_entry_button.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Future<void> pumpApp(
  WidgetTester t,
  FakeAdminRepository repo, {
  FakeAdminSeenStore? seen,
}) async {
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
        adminSeenStoreProvider.overrideWithValue(seen ?? FakeAdminSeenStore()),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

final conv = AdminItem(
  id: 'c:c1',
  kind: 'talk',
  seq: 1,
  removed: false,
  fields: {'id': 'c1', 'conv': true, 'title': 'Chat', 'at': 1000},
);

AdminItem talkMsg(String id) => AdminItem(
  id: 'm:$id',
  kind: 'talk',
  seq: 1,
  removed: false,
  fields: {
    'id': id,
    'at': 1000,
    'from': 'manager',
    'text': 'hello $id',
    'conv': 'c1',
  },
);

void main() {
  testWidgets('badge is the sum of the tab numbers and hidden at 0', (t) async {
    final seen = FakeAdminSeenStore()
      ..saved = {
        'talk': <String>{},
        'questions': <String>{},
        'tasks': <String>{},
      };
    final repo = FakeAdminRepository()
      ..fetchQueue = [
        [
          snapRow(
            1,
            1,
            items: [conv, talkMsg('m1'), qItem('Q-1'), qItem('Q-2')],
          ),
        ],
      ];
    await pumpApp(t, repo, seen: seen);

    final badgeFinder = find.descendant(
      of: find.byKey(const ValueKey('home-admin')),
      matching: find.byType(Badge),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(of: badgeFinder, matching: find.text('3')),
      findsOneWidget,
    );

    final c = ProviderScope.containerOf(
      t.element(find.byType(AdminEntryButton)),
    );
    c.read(adminPanelsProvider.notifier).markSeen('questions');
    await t.pump();
    expect(
      find.descendant(of: badgeFinder, matching: find.text('1')),
      findsOneWidget,
    );

    c.read(adminPanelsProvider.notifier).markSeen('talk');
    await t.pump();
    expect(badgeFinder, findsNothing);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('leaving Admin Panels keeps the 5 s home poll', (t) async {
    final repo = FakeAdminRepository();
    await pumpApp(t, repo);

    await t.tap(find.byKey(const ValueKey('home-admin')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(AdminPanelsScreen), findsOneWidget);

    await t.pageBack();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(AdminPanelsScreen), findsNothing);

    final after = repo.fetchCalls.length;
    await t.pump(const Duration(seconds: 30));
    final grown = repo.fetchCalls.length - after;
    expect(grown, inInclusiveRange(5, 7));

    await t.pumpWidget(const SizedBox());
  });
}

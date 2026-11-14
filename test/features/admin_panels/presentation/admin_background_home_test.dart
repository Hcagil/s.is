// test/features/admin_panels/presentation/admin_background_home_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/core/runtime_config.dart';

import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';

import '../../../support/fakes.dart';
import '../../../support/video_fakes.dart';
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
import 'package:sis/features/admin_panels/domain/admin_item.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Future<void> pumpApp(
  WidgetTester t,
  FakeAdminRepository repo, {
  FakeAdminSeenStore? seen,
  FakeAdminUnlock? unlock,
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
        adminUnlockProvider.overrideWithValue(unlock ?? FakeAdminUnlock()),
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

FakeAdminSeenStore seeded() => FakeAdminSeenStore()
  ..saved = {'talk': <String>{}, 'questions': <String>{}, 'tasks': <String>{}};

void main() {
  testWidgets(
    'owner: counts are fetched at app open and the badge shows the total before any unlock',
    (t) async {
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final seen = FakeAdminSeenStore()
        ..saved = {
          'talk': <String>{},
          'questions': <String>{},
          'tasks': <String>{},
        };
      final unlock = FakeAdminUnlock();
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
      await pumpApp(t, repo, seen: seen, unlock: unlock);
      expect(repo.fetchCalls, isNotEmpty);
      expect(unlock.calls, 0);
      final badgeFinder = find.descendant(
        of: find.byKey(const ValueKey('home-admin')),
        matching: find.byType(Badge),
      );
      expect(
        find.descendant(of: badgeFinder, matching: find.text('3')),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('not the owner: no fetch ever', (t) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    final repo = FakeAdminRepository()
      ..statusResult = const Ok<AdminStatus?>(null);
    await pumpApp(t, repo, seen: seeded());

    await t.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls, isEmpty);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-admin')),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('home polls every 5 seconds', (t) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

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
    await pumpApp(t, repo, seen: seeded());

    final base = repo.fetchCalls.length;
    await t.pump(const Duration(seconds: 4));
    expect(repo.fetchCalls.length, equals(base));
    await t.pump(const Duration(seconds: 1));
    expect(repo.fetchCalls.length, equals(base + 1));
    await t.pump(const Duration(seconds: 5));
    expect(repo.fetchCalls.length, equals(base + 2));

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('paused locks and stops, resumed restarts', (t) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

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
    await pumpApp(t, repo, seen: seeded());

    final badgeFinder = find.descendant(
      of: find.byKey(const ValueKey('home-admin')),
      matching: find.byType(Badge),
    );
    expect(
      find.descendant(of: badgeFinder, matching: find.text('3')),
      findsOneWidget,
    );

    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await t.pump();
    expect(badgeFinder, findsNothing);

    final n = repo.fetchCalls.length;
    await t.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls.length, equals(n));

    repo.fetchQueue = [
      [
        snapRow(1, 1, items: [conv, talkMsg('m1'), qItem('Q-1'), qItem('Q-2')]),
      ],
    ];
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.inactive,
    );
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await t.pump();
    await t.pump(const Duration(seconds: 5));
    expect(repo.fetchCalls.length, greaterThan(n));
    expect(
      find.descendant(of: badgeFinder, matching: find.text('3')),
      findsOneWidget,
    );

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('hidden also locks', (t) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

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
    await pumpApp(t, repo, seen: seeded());

    final badgeFinder = find.descendant(
      of: find.byKey(const ValueKey('home-admin')),
      matching: find.byType(Badge),
    );
    expect(
      find.descendant(of: badgeFinder, matching: find.text('3')),
      findsOneWidget,
    );

    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );
    await t.pump();
    expect(badgeFinder, findsNothing);

    final n = repo.fetchCalls.length;
    await t.pump(const Duration(seconds: 30));
    expect(repo.fetchCalls.length, equals(n));

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('inactive does not stop the poll', (t) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

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
    await pumpApp(t, repo, seen: seeded());

    final base = repo.fetchCalls.length;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.inactive,
    );
    await t.pump();
    await t.pump(const Duration(seconds: 5));
    expect(repo.fetchCalls.length, greaterThan(base));

    final badgeFinder = find.descendant(
      of: find.byKey(const ValueKey('home-admin')),
      matching: find.byType(Badge),
    );
    expect(
      find.descendant(of: badgeFinder, matching: find.text('3')),
      findsOneWidget,
    );

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('removing the home stops the poll', (t) async {
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

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
    await pumpApp(t, repo, seen: seeded());

    final n = repo.fetchCalls.length;
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 60));
    expect(repo.fetchCalls.length, equals(n));

    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the Admin Panels screen shows only the progress line before the unlock',
    (t) async {
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );

      final unlock = FakeAdminUnlock()..hold = Completer<AdminUnlockResult>();
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
      await pumpApp(t, repo, unlock: unlock, seen: seeded());

      await t.tap(find.byKey(const ValueKey('home-admin')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(seconds: 6));

      expect(find.byType(AdminPanelsScreen), findsOneWidget);
      expect(find.byType(SisProgressLine), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-bottom-bar')), findsNothing);
      expect(find.text('text Q-1'), findsNothing);
      expect(find.text('text Q-2'), findsNothing);

      await t.pumpWidget(const SizedBox());
    },
  );
}

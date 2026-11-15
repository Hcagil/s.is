// test/features/admin_panels/presentation/admin_entry_question_count_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
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
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

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
  fields: {
    'id': 'c1',
    'conv': true,
    'title': 'Chat',
    'at': 1000,
    'seen': 0,
    'mat': 5,
  },
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

List<AdminItem> qs(int n) => [for (var i = 1; i <= n; i++) qItem('Q-$i')];

AdminItem waitingQ(String id) => AdminItem(
  id: 'q:$id',
  kind: 'question',
  seq: 1,
  removed: false,
  fields: {
    'id': id,
    'question': 'text $id',
    'answers': ['a', 'b'],
    'state': 'waiting',
  },
);

AdminItem taskItem(String id) => AdminItem(
  id: 't:$id',
  kind: 'task',
  seq: 1,
  removed: false,
  fields: {'id': id, 'name': 'Task $id', 'change': 'change $id'},
);

FakeAdminSeenStore emptySeen() => FakeAdminSeenStore()
  ..saved = {'talk': <String>{}, 'questions': <String>{}, 'tasks': <String>{}};

Finder iconBadge() => find.descendant(
  of: find.byKey(const ValueKey('home-admin')),
  matching: find.byType(Badge),
);

Finder iconNumber(String n) =>
    find.descendant(of: iconBadge(), matching: find.text(n));

Future<ProviderContainer> start(
  WidgetTester t,
  List<AdminItem> items, {
  FakeAdminRepository? r,
}) async {
  final repo = r ?? FakeAdminRepository();
  repo.fetchQueue = [
    [snapRow(1, 1, items: items)],
  ];
  await pumpApp(t, repo, seen: emptySeen());
  await t.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(t.element(find.byType(AdminEntryButton)));
}

void main() {
  testWidgets('icon shows 5 for five unanswered questions', (t) async {
    await start(t, qs(5));
    expect(iconNumber('5'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no questions: no badge on the icon', (t) async {
    final c = await start(t, [conv]);
    await c
        .read(adminPanelsProvider.notifier)
        .markConversationRead(
          c.read(adminPanelsProvider).snapshot.conversations.first,
          5,
        );
    await t.pump();
    expect(iconBadge(), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('icon is talk plus tasks plus unanswered questions', (t) async {
    final items = [
      conv,
      talkMsg('m1'),
      taskItem('t1'),
      taskItem('t2'),
      ...qs(3),
    ];
    await start(t, items);
    expect(iconNumber('6'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('five questions, three answered: icon shows 2', (t) async {
    final c = await start(t, qs(5));
    for (var i = 1; i <= 3; i++) {
      await c.read(adminPanelsProvider.notifier).answerQuestion('Q-$i', 'a');
      await t.pump();
    }
    expect(iconNumber('2'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a question the computer reports waiting is not counted on the icon',
    (t) async {
      await start(t, [qItem('Q-1'), waitingQ('Q-2'), qItem('Q-3')]);
      expect(iconNumber('2'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('all questions answered: icon badge hidden', (t) async {
    final c = await start(t, qs(2));
    await c.read(adminPanelsProvider.notifier).answerQuestion('Q-1', 'a');
    await t.pump();
    await c.read(adminPanelsProvider.notifier).answerQuestion('Q-2', 'b');
    await t.pump();
    expect(iconBadge(), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a failed send puts the number back on the icon', (t) async {
    final repo = FakeAdminRepository();
    final c = await start(t, qs(3), r: repo);
    await c.read(adminPanelsProvider.notifier).answerQuestion('Q-1', 'a');
    await t.pump();
    expect(iconNumber('2'), findsOneWidget);
    final a = c.read(adminPanelsProvider).answers.last;
    repo.fetchQueue.add([
      deltaRow(
        2,
        2,
        cursor: 9,
        results: [failResult(a.epoch, a.upSeq, AdminAnswerCode.notOpen)],
      ),
    ]);
    await t.pump(const Duration(seconds: 6));
    expect(iconNumber('3'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}

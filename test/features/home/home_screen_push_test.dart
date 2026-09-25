// HomeScreen's seam with push: a tapped notification opens the conversation
// it names, re-reading the list once when that conversation is not on it yet
// (a chat started while the app was closed or backgrounded), and a cold start
// from a notification opens its conversation the same way. Written from
// HomeScreen's contract and lib/features/notifications/domain/push.dart --
// never the implementation.
//
// Mounted as production mounts it: SisApp behind the session gate, with fakes
// only at the repository boundary, the same pattern as the other home/settings
// suites.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const me = Member(userId: 'u1', displayName: 'Maya');

const c1 = Conversation(id: 'c1', title: 'Weekend plan');
const c2 = Conversation(id: 'c2', title: 'New project');

Future<ProviderContainer> pumpApp(
  WidgetTester t, {
  required FakeChat chat,
  required PushSourceFake push,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(
          FakeAuth(session: true, member: me),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(
          ProfileFake(
            profile: const OwnProfile(
              userId: 'u1',
              displayName: 'Maya',
              tag: 'maya',
              onboardingDone: true,
            ),
          ),
        ),
        pushSourceProvider.overrideWithValue(push),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(
    find.byType(HomeScreen, skipOffstage: false),
    findsOneWidget,
    reason: 'home did not open',
  );
  return ProviderScope.containerOf(t.element(find.byType(SisApp)));
}

void main() {
  testWidgets('a tapped notification for a conversation already on the list '
      'opens it, without re-reading the list', (t) async {
    final chat = FakeChat(list: [c1]);
    final push = PushSourceFake();
    await pumpApp(t, chat: chat, push: push);
    final readsBefore = chat.listReads;

    push.openConversation('c1');
    await t.pumpAndSettle();

    expect(find.byType(MessageScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Weekend plan'),
      ),
      findsOneWidget,
    );
    expect(
      chat.listReads,
      readsBefore,
      reason: 'a conversation already on the list needs no re-read',
    );
    expect(push.cleared, [
      'c1',
    ], reason: 'opening the tapped conversation clears its notification');
  });

  testWidgets('a tapped notification for a conversation not yet on the list '
      're-reads the list once, then opens it', (t) async {
    final chat = FakeChat(list: [c1]);
    final push = PushSourceFake();
    await pumpApp(t, chat: chat, push: push);
    final readsBefore = chat.listReads;

    // A chat started while the app was closed: the list the app already
    // loaded does not have it yet, but the server does now.
    chat.list = [c1, c2];
    push.openConversation('c2');
    await t.pumpAndSettle();

    expect(
      find.byType(MessageScreen),
      findsOneWidget,
      reason: 'the re-read must have picked up the new conversation',
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('New project'),
      ),
      findsOneWidget,
    );
    expect(
      chat.listReads,
      readsBefore + 1,
      reason: 'exactly one re-read, not a poll',
    );
    expect(push.cleared, ['c2']);
  });

  testWidgets('a notification for a conversation that is still unknown is '
      'ignored, not guessed at', (t) async {
    final chat = FakeChat(list: [c1]);
    final push = PushSourceFake();
    await pumpApp(t, chat: chat, push: push);

    push.openConversation('does-not-exist');
    await t.pumpAndSettle();

    expect(find.byType(MessageScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(
      push.cleared,
      isEmpty,
      reason: 'nothing was opened, so nothing should be cleared',
    );
  });

  testWidgets('the conversation a cold start was launched from opens '
      'automatically', (t) async {
    final chat = FakeChat(list: [c1]);
    final push = PushSourceFake(launchConversationId: 'c1');
    await pumpApp(t, chat: chat, push: push);

    expect(find.byType(MessageScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Weekend plan'),
      ),
      findsOneWidget,
    );
    expect(push.cleared, [
      'c1',
    ], reason: 'opening from a cold-start launch clears its notification too');
  });
}

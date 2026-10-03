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
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/message.dart';
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

  group('coming back to a chat that was open (0.25.2)', () {
    // The owner's bug on 0.25.1: tapping the notification of the chat that
    // was open opened it without the new messages until it was closed and
    // reopened. While the app was in the background the socket died: the
    // server has the messages, Realtime delivered none of them. FakeChat
    // models that by changing what the server answers without deliver().
    Message m(String id, String body, int minute) => Message(
      id: id,
      conversationId: 'c1',
      senderId: 'u2',
      body: body,
      createdAt: DateTime.utc(2026, 9, 29, 12, minute),
    );

    Future<(FakeChat, PushSourceFake)> openChat(WidgetTester t) async {
      final chat = FakeChat(list: [c1], initial: [m('m1', 'before', 1)]);
      final push = PushSourceFake();
      await pumpApp(t, chat: chat, push: push);
      push.openConversation('c1');
      await t.pumpAndSettle();
      expect(find.text('before'), findsOneWidget);
      // Sent while the phone slept: on the server, never delivered live.
      chat.initial = [m('m1', 'before', 1), m('m2', 'while away', 2)];
      return (chat, push);
    }

    /// Background, then foreground, the way Android reports it.
    Future<void> leaveAndReturn(WidgetTester t) async {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        t.binding.handleAppLifecycleStateChanged(s);
        await t.pump();
      }
      await t.pumpAndSettle();
    }

    testWidgets('tapping the notification of the chat already open shows its '
        'new messages, on the same screen', (t) async {
      final (_, push) = await openChat(t);

      push.openConversation('c1');
      await t.pumpAndSettle();

      expect(find.text('while away'), findsOneWidget);
      expect(
        find.byType(MessageScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'no second copy of the chat pushed on top of the first',
      );
      expect(push.cleared, ['c1', 'c1']);

      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen, skipOffstage: false), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a second notification for a chat opened from the first, '
        'tapped after going back to the list, opens it again', (t) async {
      final (_, push) = await openChat(t);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen, skipOffstage: false), findsNothing);

      push.openConversation('c1');
      await t.pumpAndSettle();

      expect(find.byType(MessageScreen), findsOneWidget);
      expect(find.text('while away'), findsOneWidget);
      expect(push.cleared, ['c1', 'c1']);
    });

    testWidgets('returning to the app shows what arrived meanwhile and clears '
        'the open chat\'s notification', (t) async {
      final (_, push) = await openChat(t);

      await leaveAndReturn(t);

      expect(find.text('while away'), findsOneWidget);
      expect(push.cleared, ['c1', 'c1']);
      expect(find.byType(MessageScreen, skipOffstage: false), findsOneWidget);
    });

    testWidgets('pulling down the notification shade is not a return: '
        'nothing is re-read', (t) async {
      final (_, push) = await openChat(t);

      for (final s in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        t.binding.handleAppLifecycleStateChanged(s);
        await t.pump();
      }
      await t.pumpAndSettle();

      expect(find.text('while away'), findsNothing);
      expect(push.cleared, ['c1']);
    });
  });

  group('Back from a chat a notification opened (0.30.8)', () {
    Future<void> back(WidgetTester t) async {
      await t.pageBack();
      await t.pumpAndSettle();
    }

    testWidgets('warm: Back lands on the list, not on the chat that was open', (
      t,
    ) async {
      final chat = FakeChat(list: [c1, c2]);
      final push = PushSourceFake();
      await pumpApp(t, chat: chat, push: push);

      await t.tap(find.text('Weekend plan'));
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);

      push.openConversation('c2');
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('New project'),
        ),
        findsOneWidget,
      );

      await back(t);
      expect(
        find.byType(MessageScreen),
        findsNothing,
        reason: 'Back must not reveal Weekend plan underneath',
      );
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('cold: Back from the launched chat lands on the list', (
      t,
    ) async {
      final chat = FakeChat(list: [c1, c2]);
      final push = PushSourceFake(launchConversationId: 'c2');
      await pumpApp(t, chat: chat, push: push);
      expect(find.byType(MessageScreen), findsOneWidget);

      await back(t);
      expect(find.byType(MessageScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Weekend plan'), findsOneWidget, reason: 'the list');
    });
  });

  group('the preview line names the sender in a group (0.30.8)', () {
    final at = DateTime.now().subtract(const Duration(minutes: 3));
    String rowText(WidgetTester t) => t
        .widgetList<RichText>(find.byType(RichText))
        .map((r) => r.text.toPlainText())
        .join('\n');

    testWidgets('someone else: "Name: message"; you: "You: message"', (
      t,
    ) async {
      final chat = FakeChat(
        list: [
          Conversation(
            id: 'g1',
            title: 'Crew',
            lastMessage: 'pizza tonight?',
            lastMessageAt: at,
            lastSenderId: 'u2',
            senders: const {'u2': GroupVoice('Bob', 1)},
          ),
          Conversation(
            id: 'g2',
            title: 'Work',
            lastMessage: 'on my way',
            lastMessageAt: at,
            lastSenderId: 'u1',
            senders: const {'u2': GroupVoice('Bob', 1)},
          ),
          Conversation(
            id: 'd1',
            other: const Member(userId: 'u3', displayName: 'Cem'),
            lastMessage: 'see you',
            lastMessageAt: at,
            lastSenderId: 'u3',
          ),
        ],
      );
      await pumpApp(t, chat: chat, push: PushSourceFake());
      final text = rowText(t);

      expect(text, contains('Bob: pizza tonight?'));
      expect(text, contains('You: on my way'));
      expect(text, contains('see you'));
      expect(text, isNot(contains('Cem: see you')), reason: '1:1 unchanged');
    });
  });
}

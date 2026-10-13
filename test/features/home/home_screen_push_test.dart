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
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/core/failure.dart';
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
import '../../support/video_fakes.dart';

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
  required ChatRepository chat,
  required PushSourceFake push,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(),
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

/// The tap's route is on the Navigator within these frames, whatever the
/// list is doing: the stream event, then the push (a route cannot be pushed
/// mid-build). Nothing here waits for a read -- the list's is held open.
Future<void> nextFrames(WidgetTester t) async {
  await t.pump();
  await t.pump();
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

  // 0.30.12: a tap opens the chat at once; one the list never learns about
  // (after it settles and one quiet re-read) is closed again.
  testWidgets('a notification for a conversation that is still unknown opens '
      'at once, and is closed again when the list never learns it', (t) async {
    final chat = FakeChat(list: [c1]);
    final push = PushSourceFake();
    await pumpApp(t, chat: chat, push: push);
    // Re-reads are held, so the chat is seen open before the list decides.
    final gate = chat.listGate = Completer<void>();

    push.openConversation('does-not-exist');
    await nextFrames(t);
    expect(
      find.byType(MessageScreen, skipOffstage: false),
      findsOneWidget,
      reason: 'the tap must open something at once',
    );
    expect(
      find.descendant(
        of: find.byType(AppBar, skipOffstage: false),
        matching: find.text('Conversation', skipOffstage: false),
        skipOffstage: false,
      ),
      findsOneWidget,
      reason: 'an unknown chat has a neutral title, not a guess',
    );

    gate.complete();
    chat.listGate = null;
    await t.pumpAndSettle();
    expect(find.byType(MessageScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a tap while the list is re-reading opens the chat in the same '
      'frame, titled from the list it already holds', (t) async {
    final chat = FakeChat(list: [c1, c2]);
    final push = PushSourceFake();
    final c = await pumpApp(t, chat: chat, push: push);
    final gate = chat.listGate = Completer<void>();
    c.invalidate(conversationListProvider);
    await t.pump();

    push.openConversation('c1');
    await nextFrames(t);
    expect(find.byType(MessageScreen, skipOffstage: false), findsOneWidget);
    expect(c.read(openConversationProvider), 'c1');

    gate.complete();
    chat.listGate = null;
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Weekend plan'),
      ),
      findsOneWidget,
    );
    expect(find.byType(MessageScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets('a tap for another chat while one is open replaces it in the '
      'same frame, even while the list is re-reading', (t) async {
    final chat = FakeChat(list: [c1, c2]);
    final push = PushSourceFake();
    final c = await pumpApp(t, chat: chat, push: push);
    await t.tap(find.text('Weekend plan'));
    await t.pumpAndSettle();
    final gate = chat.listGate = Completer<void>();
    c.invalidate(conversationListProvider);
    await t.pump();

    push.openConversation('c2');
    await nextFrames(t);
    expect(c.read(openConversationProvider), 'c2');

    gate.complete();
    chat.listGate = null;
    await t.pumpAndSettle();
    expect(find.byType(MessageScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('New project'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a chat unknown at the tap but learned by the list stays open, '
      'its title filled in', (t) async {
    final chat = FakeChat(list: [c1]);
    final push = PushSourceFake();
    final c = await pumpApp(t, chat: chat, push: push);
    final gate = chat.listGate = Completer<void>();
    c.invalidate(conversationListProvider);
    await t.pump();

    chat.list = [c1, c2]; // the server has it; the list does not yet
    push.openConversation('c2');
    await nextFrames(t);
    expect(find.byType(MessageScreen, skipOffstage: false), findsOneWidget);

    gate.complete();
    chat.listGate = null;
    await t.pumpAndSettle();
    expect(find.byType(MessageScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('New project'),
      ),
      findsOneWidget,
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

    testWidgets('the chat that was open is no longer open: a new message in '
        'it counts as unread, before and after Back', (t) async {
      final earlier = DateTime.now().subtract(const Duration(hours: 1));
      // ChatFake is the database too: an insert is a row, unread included.
      final chat = ChatFake(self: 'u1')
        ..conversationsResult = Ok([
          Conversation(
            id: 'c1',
            title: 'Weekend plan',
            lastMessage: 'hi',
            lastMessageAt: earlier,
            lastSenderId: 'u2',
          ),
          Conversation(
            id: 'c2',
            title: 'New project',
            lastMessage: 'yo',
            lastMessageAt: earlier,
            lastSenderId: 'u2',
          ),
        ]);
      final push = PushSourceFake();
      final c = await pumpApp(t, chat: chat, push: push);
      int unreadC1() => c
          .read(conversationListProvider)
          .value!
          .singleWhere((x) => x.id == 'c1')
          .unread;
      Message inC1(String id) => Message(
        id: id,
        conversationId: 'c1',
        senderId: 'u2',
        body: 'still there?',
        createdAt: DateTime.now(),
      );

      await t.tap(find.text('Weekend plan'));
      await t.pumpAndSettle();
      expect(c.read(openConversationProvider), 'c1');

      push.openConversation('c2');
      await t.pumpAndSettle();
      expect(c.read(openConversationProvider), 'c2');
      chat.deliver(inC1('m1'));
      await t.pumpAndSettle();
      expect(unreadC1(), 1, reason: 'c1 is not being viewed');

      await back(t);
      expect(
        c.read(openConversationProvider),
        isNull,
        reason: 'Back from c2 must not reopen c1 as the viewed chat',
      );
      chat.deliver(inC1('m2'));
      await t.pumpAndSettle();
      expect(unreadC1(), 2, reason: 'not suppressed as "currently viewing"');
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

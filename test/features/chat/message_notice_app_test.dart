// The top card in the whole app, mounted as main.dart mounts it (SisApp, its
// MessageNoticeHost and navigatorKey); fakes only at the repository and push
// boundary. Written by QA from the contract only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_notice_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/archive_fakes.dart';
import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');
const cem = Member(userId: 'uc', displayName: 'Cem Ak');

Finder byKey(String key) => find.byKey(ValueKey(key));
final cardFinder = byKey('message-notice');

List<Conversation> twoChats() {
  final now = DateTime.now().toUtc();
  return [
    Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(const Duration(minutes: 1)),
      lastSenderId: bob.userId,
    ),
    Conversation(
      id: 'c2',
      other: cem,
      lastMessage: 'yo',
      lastMessageAt: now.subtract(const Duration(minutes: 2)),
      lastSenderId: cem.userId,
    ),
  ];
}

Message fromCem(String body) => Message(
  id: 'm-$body',
  conversationId: 'c2',
  senderId: cem.userId,
  body: body,
  createdAt: DateTime.now().toUtc(),
);

class App {
  App(this.chat, this.push, this.c);
  final ChatFake chat;
  final PushSourceFake push;
  final ProviderContainer c;
}

Future<void> steps(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// The app on the chat list, then chat c1 opened by a tap on its row.
Future<App> openC1(WidgetTester t, {List<Mute> mutes = const []}) async {
  final chat = ChatFake()..conversationsResult = Ok(twoChats());
  final push = PushSourceFake();
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
        notificationSettingsRepositoryProvider.overrideWithValue(
          NotificationSettingsFake(
            mutes: mutes,
            latency: const Duration(milliseconds: 40),
          ),
        ),
        chatArchiveRepositoryProvider.overrideWithValue(ChatArchiveFake()),
        pushSourceProvider.overrideWithValue(push),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        notificationExplainerStoreProvider.overrideWithValue(
          NotificationExplainerStoreFake(shown: true),
        ),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c2'), findsOneWidget, reason: 'no list');
  final c = ProviderScope.containerOf(t.element(find.byType(SisApp)));
  await t.tap(byKey('conversation-c1'));
  await steps(t, 20);
  expect(c.read(openConversationProvider), 'c1');
  return App(chat, push, c);
}

/// What is on screen after a way of opening c2: the open chat, how many
/// message screens are stacked, and what one back leads to.
Future<(String?, int, bool)> afterOpen(WidgetTester t, App a) async {
  final open = a.c.read(openConversationProvider);
  final screens = find
      .byType(MessageScreen, skipOffstage: false)
      .evaluate()
      .length;
  await t.binding.handlePopRoute();
  await steps(t, 20);
  final backOnList =
      find.byType(MessageScreen).evaluate().isEmpty &&
      byKey('conversation-c2').evaluate().isNotEmpty;
  return (open, screens, backOnList);
}

void main() {
  testWidgets('a message from chat c2 while c1 is open shows the card; a tap '
      'opens c2 on top of the list, as a notification tap does', (t) async {
    final a = await openC1(t);

    a.chat.deliver(fromCem('are you there'));
    await steps(t, 2);
    expect(cardFinder, findsOneWidget);
    expect(
      find.descendant(of: cardFinder, matching: find.text('Cem Ak')),
      findsOneWidget,
      reason: 'name from the list',
    );

    await t.tap(cardFinder);
    await steps(t, 20);
    expect(cardFinder, findsNothing);
    expect(a.c.read(messageNoticeProvider), isNull);
    final byCard = await afterOpen(t, a);

    // The same, by a notification tap, from c1 again.
    await t.tap(byKey('conversation-c1'));
    await steps(t, 20);
    a.push.openConversation('c2');
    await steps(t, 20);
    final byPush = await afterOpen(t, a);

    expect(byCard.$1, 'c2');
    expect(byCard.$2, 1, reason: 'c2 alone on top of the list, c1 gone');
    expect(byCard.$3, isTrue, reason: 'back from c2 should be the list');
    expect(byCard, byPush, reason: 'card tap and notification tap differ');
  });

  testWidgets('a muted chat raises no card in the real app', (t) async {
    final a = await openC1(
      t,
      mutes: const [Mute(kind: MuteKind.conversation, target: 'c2')],
    );
    a.chat.deliver(fromCem('quiet'));
    await steps(t, 4);
    expect(cardFinder, findsNothing);
    expect(a.c.read(messageNoticeProvider), isNull);
  });
}

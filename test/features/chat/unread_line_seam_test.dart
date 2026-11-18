import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/pin_fakes.dart';
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

List<Message> msgs(String conversationId, int n, {String other = 'u2'}) => [
  for (var i = 0; i < n; i++)
    Message(
      id: 'k-$i',
      conversationId: conversationId,
      senderId: other,
      body: 'hay $i',
      createdAt: DateTime.utc(2026, 9, 1, 8).add(Duration(minutes: i)),
    ),
];

const c1Id = '00000000-0000-4000-8000-0000000000c1';
const g1Id = '00000000-0000-4000-8000-0000000000a1';

final divider = find.byKey(const ValueKey('unread-divider'));
Finder row(int i) => find.text('hay $i', findRichText: true);
double dy(WidgetTester t, Finder f) => t.getTopLeft(f).dy;

Conversation c1row = Conversation(
  id: c1Id,
  other: bob,
  lastMessage: 'hi',
  lastMessageAt: DateTime.utc(2026, 9, 1, 8, 59),
  lastSenderId: bob.userId,
  unread: 5,
);
Conversation g1row = Conversation(
  id: g1Id,
  title: 'Club',
  lastMessage: 'yo',
  lastMessageAt: DateTime.utc(2026, 9, 1, 8, 57),
  lastSenderId: bob.userId,
  unread: 4,
);

ChatFake fakeChat() {
  final chat = ChatFake()
    ..conversationsResult = Ok([c1row, g1row])
    ..history[c1Id] = msgs(c1Id, 30)
    ..history[g1Id] = [
      for (var i = 0; i < 30; i++)
        Message(
          id: 'k-$i',
          conversationId: g1Id,
          senderId: i % 3 == 0 ? 'ub' : 'u2',
          body: 'hay $i',
          createdAt: DateTime.utc(2026, 9, 1, 8).add(Duration(minutes: i)),
        ),
    ];
  return chat;
}

Future<ProviderContainer> pumpList(
  WidgetTester t, {
  required ChatFake chat,
  required PushSourceFake push,
}) async {
  await t.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('screen'),
      child: ProviderScope(
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
              mutes: const [],
              latency: const Duration(milliseconds: 40),
            ),
          ),
          chatArchiveRepositoryProvider.overrideWithValue(ChatArchiveFake()),
          pushSourceProvider.overrideWithValue(push),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          notificationExplainerStoreProvider.overrideWithValue(
            NotificationExplainerStoreFake(shown: true),
          ),
          chatPinRepositoryProvider.overrideWithValue(ChatPinFake()),
          chatDeleteRepositoryProvider.overrideWithValue(ChatDeleteFake()),
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  return ProviderScope.containerOf(t.element(find.byType(SisApp)));
}

void main() {
  testWidgets(
    'second open of the same chat: no line (count is 0 after the first open read it)',
    (WidgetTester t) async {
      final chat = fakeChat();
      final push = PushSourceFake();
      await pumpList(t, chat: chat, push: push);
      await t.tap(byKey('conversation-$c1Id'));
      await t.pumpAndSettle();
      expect(divider, findsOneWidget, reason: 'divider shown after first open');
      expect(
        dy(t, row(24)) < dy(t, divider) && dy(t, divider) < dy(t, row(25)),
        isTrue,
        reason: 'divider between 24 and 25 after first open',
      );
      await t.pageBack();
      await t.pumpAndSettle();
      await t.tap(byKey('conversation-$c1Id'));
      await t.pumpAndSettle();
      expect(
        divider,
        findsNothing,
        reason: 'divider removed after second open',
      );
      expect(
        row(29),
        findsOneWidget,
        reason: 'last message visible after second open',
      );
    },
  );

  testWidgets(
    'group chat opened from the list: line between the last read and the first unread, group senders skipped correctly',
    (WidgetTester t) async {
      final chat = fakeChat();
      final push = PushSourceFake();
      await pumpList(t, chat: chat, push: push);
      await t.tap(byKey('conversation-$g1Id'));
      await t.pumpAndSettle();
      expect(divider, findsOneWidget, reason: 'divider shown for group chat');
      expect(
        dy(t, row(25)) < dy(t, divider) && dy(t, divider) < dy(t, row(26)),
        isTrue,
        reason: 'divider between 25 and 26 for group chat',
      );
    },
  );

  testWidgets(
    'notification tap opens the chat and the line shows (count taken before mark-read)',
    (WidgetTester t) async {
      final chat = fakeChat();
      final push = PushSourceFake();
      await pumpList(t, chat: chat, push: push);
      push.openConversation(c1Id);
      await t.pumpAndSettle();
      expect(
        divider,
        findsOneWidget,
        reason: 'divider shown after notification tap',
      );
      expect(
        dy(t, row(24)) < dy(t, divider) && dy(t, divider) < dy(t, row(25)),
        isTrue,
        reason: 'divider between 24 and 25 after notification tap',
      );
      expect(
        chat.markedRead,
        contains(c1Id),
        reason: 'chat marked as read after notification tap',
      );
    },
  );
}

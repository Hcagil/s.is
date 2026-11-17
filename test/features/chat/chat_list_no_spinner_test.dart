import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<NotificationSettingsFake> pumpList(
  WidgetTester t, {
  List<Mute> mutes = const [],
  ChatFake? chat,
  ChatArchiveFake? archive,
  int unread = 0,
}) async {
  final notif = NotificationSettingsFake(
    mutes: mutes,
    latency: const Duration(milliseconds: 40),
  );
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
          chatRepositoryProvider.overrideWithValue(
            chat ??
                (ChatFake()..conversationsResult = Ok(chats(unread: unread))),
          ),
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
          notificationSettingsRepositoryProvider.overrideWithValue(notif),
          chatArchiveRepositoryProvider.overrideWithValue(
            archive ?? ChatArchiveFake(),
          ),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          notificationExplainerStoreProvider.overrideWithValue(
            NotificationExplainerStoreFake(shown: true),
          ),
          chatDeleteRepositoryProvider.overrideWithValue(ChatDeleteFake()),
        ],
        child: const SisApp(),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return notif;
}

List<Conversation> chats({int unread = 0}) {
  final now = DateTime.now().toUtc();
  return [
    Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(const Duration(minutes: 1)),
      lastSenderId: bob.userId,
      unread: unread,
    ),
    Conversation(
      id: 'c2',
      other: bob,
      lastMessage: 'yo',
      lastMessageAt: now.subtract(const Duration(minutes: 2)),
      lastSenderId: bob.userId,
      unread: unread,
    ),
  ];
}

void main() {
  group('chat list no spinner', () {
    testWidgets('loading with no value: no loading logo on the list', (
      t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok(chats())
        ..holdList();
      await pumpList(t, chat: chat);
      // Pump a few times without releasing the list
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SisLoadingLogo), findsNothing);
      expect(byKey('conversation-c1'), findsNothing);
    });

    testWidgets('when the list arrives it shows', (t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok(chats())
        ..holdList();
      await pumpList(t, chat: chat);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      chat.releaseList();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(byKey('conversation-c1'), findsOneWidget);
      expect(find.byType(SisLoadingLogo), findsNothing);
    });
  });
}

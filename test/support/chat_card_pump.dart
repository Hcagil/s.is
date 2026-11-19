import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import 'archive_fakes.dart';
import 'chat_delete_fakes.dart';
import 'fakes.dart';
import 'mark_fakes.dart';
import 'pin_fakes.dart';
import 'video_fakes.dart';

const cardConfig = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');
const cem = Member(userId: 'uc', displayName: 'Cem Ak');

Finder byKey(String key) => find.byKey(ValueKey(key));

Conversation conv(
  String id,
  Member other,
  int minute, {
  int unread = 0,
  bool marked = false,
  bool archived = false,
  bool pinned = false,
}) {
  final now = DateTime.now().toUtc();
  return Conversation(
    id: id,
    other: other,
    lastMessage: 'hi $id',
    lastMessageAt: now.subtract(Duration(minutes: minute)),
    lastSenderId: other.userId,
    unread: unread,
    markedUnread: marked,
    archived: archived,
    pinned: pinned,
  );
}

Future<void> pumpCardList(
  WidgetTester t, {
  required ChatFake chat,
  MarkFake? mark,
  ChatArchiveFake? archive,
  ChatPinFake? pins,
  ChatDeleteFake? del,
  Locale? locale,
}) async {
  mark ??= MarkFake();
  archive ??= ChatArchiveFake();
  pins ??= ChatPinFake();
  del ??= ChatDeleteFake(chat: chat);

  final notif = NotificationSettingsFake(
    mutes: const [],
    latency: const Duration(milliseconds: 40),
  );

  if (locale != null) {
    t.platformDispatcher.localesTestValue = [locale];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
  }

  await t.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('screen'),
      child: ProviderScope(
        overrides: [
          ...videoOverrides(),
          runtimeConfigProvider.overrideWithValue(cardConfig),
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
          notificationSettingsRepositoryProvider.overrideWithValue(notif),
          chatArchiveRepositoryProvider.overrideWithValue(archive),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          notificationExplainerStoreProvider.overrideWithValue(
            NotificationExplainerStoreFake(shown: true),
          ),
          chatDeleteRepositoryProvider.overrideWithValue(del),
          chatMarkRepositoryProvider.overrideWithValue(mark),
          chatPinRepositoryProvider.overrideWithValue(pins),
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c1'), findsOneWidget, reason: 'no list');
}

Future<void> openCard(WidgetTester t, String id) async {
  await t.longPress(byKey('conversation-$id'));
  await t.pumpAndSettle();
  expect(byKey('chat-menu'), findsOneWidget);
}

int weight(WidgetTester t, Finder of) {
  var w = 0;
  for (final r in t.widgetList<RichText>(
    find.descendant(of: of, matching: find.byType(RichText)),
  )) {
    final fw = r.text.style?.fontWeight;
    if (fw != null && fw.value > w) w = fw.value;
  }
  return w;
}

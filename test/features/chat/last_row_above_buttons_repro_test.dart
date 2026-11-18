import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
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

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/group_settings_fakes.dart';
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

List<Conversation> rows() {
  final now = DateTime.now().toUtc();
  Conversation at(int i, Conversation c) => Conversation(
    id: c.id,
    title: c.title,
    other: c.other,
    isAdmin: c.isAdmin,
    isSystem: c.isSystem,
    lastMessage: 'hi ${c.id}',
    lastMessageAt: now.subtract(Duration(minutes: i + 1)),
    lastSenderId: c.other?.userId,
  );
  final List<Conversation> list = [];
  for (var i = 0; i < 30; i++) {
    list.add(
      at(
        i,
        Conversation(
          id: 'c$i',
          other: Member(userId: 'u$i', displayName: 'Person $i'),
        ),
      ),
    );
  }
  return list;
}

typedef World = ({ChatFake chat, ChatDeleteFake del, GroupSettingsFake groups});

Future<World> pumpList(WidgetTester t, {bool tr = false}) async {
  if (tr) {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
  }
  final chat = ChatFake(self: me.userId)..conversationsResult = Ok(rows());
  final del = ChatDeleteFake(chat: chat);
  final groups = GroupSettingsFake();
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
          NotificationSettingsFake(),
        ),
        chatArchiveRepositoryProvider.overrideWithValue(ChatArchiveFake()),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        notificationExplainerStoreProvider.overrideWithValue(
          NotificationExplainerStoreFake(shown: true),
        ),
        chatPinRepositoryProvider.overrideWithValue(ChatPinFake()),
        chatDeleteRepositoryProvider.overrideWithValue(del),
        groupSettingsRepositoryProvider.overrideWithValue(groups),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c1'), findsOneWidget, reason: 'no list');
  return (chat: chat, del: del, groups: groups);
}

void main() {
  final records = [
    (
      name: 'iPhone with bottom safe area',
      size: const Size(390, 844),
      ratio: 3.0,
      bottomInset: 34.0,
    ),
    (
      name: 'plain Android',
      size: const Size(360, 640),
      ratio: 2.0,
      bottomInset: 0.0,
    ),
  ];

  for (final s in records) {
    testWidgets(
      'Last chat row ends above the new chat / new group buttons when scrolled to the end (${s.name})',
      (t) async {
        t.view.physicalSize = s.size * s.ratio;
        t.view.devicePixelRatio = s.ratio;
        addTearDown(t.view.reset);

        if (s.bottomInset > 0) {
          final padding = FakeViewPadding(bottom: s.bottomInset * s.ratio);
          t.view.padding = padding;
          t.view.viewPadding = padding;
          addTearDown(t.view.resetPadding);
          addTearDown(t.view.resetViewPadding);
        }

        await pumpList(t);

        // Scroll to the end
        for (var i = 0; i < 5; i++) {
          await t.fling(
            find
                .byWidgetPredicate(
                  (w) => w is Scrollable && w.axis == Axis.vertical,
                )
                .first,
            const Offset(0, -2000),
            3000,
          );
          await t.pumpAndSettle();
        }

        expect(
          byKey('conversation-c29'),
          findsOneWidget,
          reason: 'list did not reach the end',
        );

        final lastRect = t.getRect(byKey('conversation-c29'));
        final chatRect = t.getRect(byKey('new-chat'));
        final groupRect = t.getRect(byKey('new-group'));
        final buttonsTop = min(chatRect.top, groupRect.top);

        expect(
          lastRect.bottom <= buttonsTop,
          isTrue,
          reason:
              'last row: $lastRect, new-chat: $chatRect, new-group: $groupRect, rows hide ${lastRect.bottom - buttonsTop} px under the buttons',
        );
      },
    );
  }
}

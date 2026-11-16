import 'dart:async';

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
  return [
    at(0, const Conversation(id: 'c1', other: bob)),
    at(1, const Conversation(id: 'c2', other: cem)),
    at(2, const Conversation(id: 'g1', title: 'Trip')),
    at(3, const Conversation(id: 'g2', title: 'Club', isAdmin: true)),
    at(
      4,
      const Conversation(
        id: 's',
        isSystem: true,
        other: Member(userId: 'sys', displayName: 'SIS'),
      ),
    ),
  ];
}

typedef World = ({ChatArchiveFake archive, ChatDeleteFake del});

Future<World> pumpList(
  WidgetTester t, {
  required ChatArchiveFake archive,
  required ChatDeleteFake del,
  bool tr = false,
}) async {
  if (tr) {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
  }
  final chat = ChatFake(self: me.userId)..conversationsResult = Ok(rows());
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
        chatArchiveRepositoryProvider.overrideWithValue(archive),
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
  return (archive: archive, del: del);
}

Future<void> select(WidgetTester t, List<String> ids) async {
  await t.longPress(byKey('conversation-${ids.first}'));
  await t.pumpAndSettle();
  for (final id in ids.skip(1)) {
    await t.tap(byKey('conversation-$id'));
    await t.pumpAndSettle();
  }
}

Future<void> openDelete(WidgetTester t, List<String> ids) async {
  await select(t, ids);
  await t.tap(byKey('selection-delete'));
  await t.pumpAndSettle();
}

Future<void> confirm(WidgetTester t) async {
  await t.tap(byKey('delete-chat-ok'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> runOut(WidgetTester t) async {
  for (var i = 0; i < 7; i++) {
    await t.pump(const Duration(seconds: 1));
  }
  await t.pumpAndSettle();
}

String count(WidgetTester t) =>
    t
        .widget<Text>(
          find.descendant(
            of: byKey('selection-count'),
            matching: find.byType(Text),
            matchRoot: true,
          ),
        )
        .data ??
    '';

void main() {
  testWidgets(
    'confirming Delete after the selection bar left the screen starts no delete and throws nothing',
    (t) async {
      final archive = ChatArchiveFake()..hold = Completer<void>();
      final del = ChatDeleteFake(chat: ChatFake(self: me.userId));
      await pumpList(t, archive: archive, del: del);

      await select(t, ['c1']);
      expect(byKey('selection-delete'), findsOneWidget);

      await t.tap(byKey('selection-more'));
      await t.pumpAndSettle();
      await t.tap(byKey('selection-archive'));
      await t.pump(const Duration(milliseconds: 100));

      expect(archive.calls.length, 1);
      expect(byKey('selection-count'), findsOneWidget);

      await t.tap(byKey('selection-delete'));
      await t.pumpAndSettle();
      expect(byKey('delete-chat-ok'), findsOneWidget);

      archive.hold!.complete();
      await t.pump(const Duration(milliseconds: 100));

      expect(byKey('selection-count'), findsNothing);
      if (byKey('delete-chat-ok').evaluate().isNotEmpty) {
        expect(byKey('delete-chat-ok'), findsOneWidget);
      }

      await t.tap(byKey('delete-chat-ok'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await runOut(t);

      expect(t.takeException(), isNull);
      expect(del.calls, isEmpty);
      expect(archive.calls.length, 1);
    },
  );
}

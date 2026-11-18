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

List<Conversation>? rowsOverride;

List<Conversation> rows() {
  if (rowsOverride != null) return rowsOverride!;
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

Future<void> select(WidgetTester t, List<String> ids) async {
  await t.longPress(byKey('conversation-${ids.first}'));
  await t.pumpAndSettle();
  await t.tap(byKey('chat-menu-select'));
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

Finder rich(String s) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().contains(s),
);

void main() {
  testWidgets('baseline 1:1 with messages', (WidgetTester t) async {
    await pumpList(t);
    await openDelete(t, ['c1']);
    expect(
      byKey('delete-chat-ok'),
      findsOneWidget,
      reason: 'baseline 1:1 with messages: no confirm box',
    );
    expect(
      rich('just for you'),
      findsOneWidget,
      reason: 'baseline 1:1 with messages: wrong text',
    );
    expect(
      byKey('chat-undo-bar'),
      findsNothing,
      reason: 'baseline 1:1 with messages: deleted at once',
    );
    expect(
      byKey('conversation-c1'),
      findsOneWidget,
      reason: 'baseline 1:1 with messages: chat vanished before confirm',
    );
  });

  testWidgets('Turkish 1:1', (WidgetTester t) async {
    await pumpList(t, tr: true);
    await openDelete(t, ['c1']);
    expect(
      byKey('delete-chat-ok'),
      findsOneWidget,
      reason: 'Turkish 1:1: no confirm box',
    );
    expect(
      byKey('chat-undo-bar'),
      findsNothing,
      reason: 'Turkish 1:1: deleted at once',
    );
    expect(
      byKey('conversation-c1'),
      findsOneWidget,
      reason: 'Turkish 1:1: chat vanished before confirm',
    );
  });

  testWidgets('empty 1:1, no messages yet', (WidgetTester t) async {
    rowsOverride = [
      const Conversation(id: 'c1', other: bob),
      const Conversation(id: 'c2', other: cem),
    ];
    addTearDown(() => rowsOverride = null);
    await pumpList(t);
    await openDelete(t, ['c1']);
    expect(
      byKey('delete-chat-ok'),
      findsOneWidget,
      reason: 'empty 1:1: no confirm box',
    );
    expect(
      rich('just for you'),
      findsOneWidget,
      reason: 'empty 1:1: wrong text',
    );
    expect(
      byKey('chat-undo-bar'),
      findsNothing,
      reason: 'empty 1:1: deleted at once',
    );
    expect(
      byKey('conversation-c1'),
      findsOneWidget,
      reason: 'empty 1:1: chat vanished before confirm',
    );
  });

  testWidgets('second delete while the first Undo bar is showing', (
    WidgetTester t,
  ) async {
    await pumpList(t);
    await openDelete(t, ['c1']);
    await confirm(t);
    expect(
      byKey('chat-undo-bar'),
      findsOneWidget,
      reason: 'second delete: undo bar should be present',
    );
    await openDelete(t, ['c2']);
    expect(
      byKey('delete-chat-ok'),
      findsOneWidget,
      reason: 'second delete: no confirm box',
    );
    expect(
      rich('just for you'),
      findsOneWidget,
      reason: 'second delete: wrong text',
    );
    expect(
      byKey('conversation-c2'),
      findsOneWidget,
      reason: 'second delete: chat vanished before confirm',
    );
  });

  testWidgets('tap Delete in the selection bar a second time quickly', (
    WidgetTester t,
  ) async {
    await pumpList(t);
    await t.longPress(byKey('conversation-c1'));
    await t.pumpAndSettle();
    await t.tap(byKey('chat-menu-select'));
    await t.pumpAndSettle();
    await t.tap(byKey('selection-delete'));
    await t.pump(); // no settle
    await t.pumpAndSettle();
    expect(
      byKey('delete-chat-ok'),
      findsOneWidget,
      reason: 'quick delete: no confirm box',
    );
    expect(
      rich('just for you'),
      findsOneWidget,
      reason: 'quick delete: wrong text',
    );
    expect(
      byKey('chat-undo-bar'),
      findsNothing,
      reason: 'quick delete: deleted at once',
    );
    expect(
      byKey('conversation-c1'),
      findsOneWidget,
      reason: 'quick delete: chat vanished before confirm',
    );
  });
}

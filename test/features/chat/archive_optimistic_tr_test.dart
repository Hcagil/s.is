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
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/archive_fakes.dart';
import '../../support/fakes.dart';
import '../../support/sis_ui.dart' as ui;

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');
const cem = Member(userId: 'uc', displayName: 'Cem Ak');

Finder byKey(String key) => find.byKey(ValueKey(key));

/// Two chats: c1 with Bob, c2 with Cem, each with [unread] messages unread.
/// `c1Archived` controls whether c1 is archived.
List<Conversation> list({bool c1Archived = false, int c1Unread = 0}) {
  final now = DateTime.now().toUtc();
  return [
    Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(const Duration(minutes: 1)),
      lastSenderId: bob.userId,
      unread: c1Unread,
      archived: c1Archived,
    ),
    Conversation(
      id: 'c2',
      other: cem,
      lastMessage: 'yo',
      lastMessageAt: now.subtract(const Duration(minutes: 2)),
      lastSenderId: cem.userId,
      unread: 0,
      archived: false,
    ),
  ];
}

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
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(
            FakeAuth(session: true, member: me),
          ),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(
            chat ??
                (ChatFake()..conversationsResult = Ok(list(c1Unread: unread))),
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
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c2'), findsOneWidget, reason: 'no list');
  return notif;
}

void main() {
  Future<void> commit(WidgetTester t, String id) async {
    final g = await t.startGesture(t.getCenter(byKey('archive-swipe-$id')));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-10, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
  }

  Future<TestGesture> partial(WidgetTester t, String id) async {
    final g = await t.startGesture(t.getCenter(byKey('archive-swipe-$id')));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(-10, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    return g;
  }

  Finder archivedRow() =>
      find.byKey(const ValueKey('archived-chats-row'), skipOffstage: false);

  Future<void> openArchived(WidgetTester t) async {
    await t.drag(byKey('conversation-list'), const Offset(0, 120));
    await t.pumpAndSettle();
    await t.tap(byKey('archived-chats-row'));
    await t.pumpAndSettle();
  }

  testWidgets('archive is optimistic', (WidgetTester t) async {
    final archive = ChatArchiveFake()..hold = Completer<void>();
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list()),
      archive: archive,
    );
    await commit(t, 'c1');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('conversation-c1')), findsNothing);
    expect(
      archive.calls.map((e) => (e.key, e.value)).toList(),
      equals([('c1', true)]),
    );
    archive.hold!.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-c1')), findsNothing);
    expect(archivedRow(), findsOneWidget);
  });

  testWidgets('a refused archive puts the chat back and shows a notice', (
    WidgetTester t,
  ) async {
    final archive = ChatArchiveFake()
      ..result = const Err(NetworkFailure('offline'));
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list()),
      archive: archive,
    );
    await commit(t, 'c1');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    expect(archivedRow(), findsNothing);
    expect(ui.notice, findsOneWidget);
    await ui.drainNotice(t);
  });

  testWidgets('English pill label', (WidgetTester t) async {
    await pumpList(t, chat: ChatFake()..conversationsResult = Ok(list()));
    final g = await partial(t, 'c2');
    expect(find.text('Archive'), findsOneWidget);
    await g.cancel();
    await t.pumpAndSettle();
  });

  testWidgets('Turkish labels and title', (WidgetTester t) async {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list(c1Archived: true)),
      archive: ChatArchiveFake(archived: {'c1'}),
    );
    final g2 = await partial(t, 'c2');
    expect(find.text('Arşivle'), findsOneWidget);
    await g2.cancel();
    await t.pumpAndSettle();

    await openArchived(t);
    expect(find.text('Arşivlenen sohbetler'), findsWidgets);

    final g1 = await partial(t, 'c1');
    expect(find.text('Arşivden çıkar'), findsOneWidget);
    await g1.cancel();
    await t.pumpAndSettle();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_list_filter.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/pin_fakes.dart';
import '../../support/video_fakes.dart';
import '../../support/l10n.dart' as l10n;

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');
const cem = Member(userId: 'uc', displayName: 'Cem Ak');

Finder byKey(String key) => find.byKey(ValueKey(key));

/// Builds the list of conversations used in the filter tests.
List<Conversation> rows({bool g3Archived = true, bool g2Pinned = false}) {
  final now = DateTime.now().toUtc();
  return [
    Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(const Duration(minutes: 1)),
      lastSenderId: bob.userId,
      unread: 0,
    ),
    Conversation(
      id: 'c2',
      other: cem,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(const Duration(minutes: 2)),
      lastSenderId: cem.userId,
      unread: 0,
    ),
    Conversation(
      id: 'g1',
      title: 'Club',
      lastMessage: 'yo',
      lastMessageAt: now.subtract(const Duration(minutes: 3)),
      lastSenderId: bob.userId,
      pinned: false,
    ),
    Conversation(
      id: 'g2',
      title: 'Trip',
      lastMessage: 'yo',
      lastMessageAt: now.subtract(const Duration(minutes: 4)),
      lastSenderId: bob.userId,
      pinned: g2Pinned,
    ),
    Conversation(
      id: 'g3',
      title: 'Old group',
      archived: g3Archived,
      lastMessage: 'x',
      lastMessageAt: now.subtract(const Duration(minutes: 5)),
      lastSenderId: bob.userId,
    ),
  ];
}

Future<NotificationSettingsFake> pumpList(
  WidgetTester t, {
  List<Mute> mutes = const [],
  ChatFake? chat,
  ChatArchiveFake? archive,
  int unread = 0,
  ChatPinFake? pins,
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
            chat ?? (ChatFake()..conversationsResult = Ok(rows())),
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
          chatPinRepositoryProvider.overrideWithValue(pins ?? ChatPinFake()),
          chatDeleteRepositoryProvider.overrideWithValue(ChatDeleteFake()),
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  return notif;
}

/// Awaits [call] while pumping: the fakes' hops are timers on the test clock.
Future<void> drive(WidgetTester t, Future<void> call) async {
  var done = false;
  call.whenComplete(() => done = true).ignore();
  for (var i = 0; i < 200 && !done; i++) {
    await t.pump(Duration.zero);
  }
  expect(done, isTrue, reason: 'the call never completed');
  await call;
  await t.pumpAndSettle();
}

void main() {
  testWidgets('default shows 1:1 chats and groups, provider false', (
    WidgetTester t,
  ) async {
    await pumpList(t);
    expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g2')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g3')), findsNothing);
    final container = ProviderScope.containerOf(t.element(find.byType(SisApp)));
    expect(container.read(chatListGroupsOnlyProvider), isFalse);
  });

  testWidgets('tap Groups shows only non‑archived groups', (
    WidgetTester t,
  ) async {
    await pumpList(t);
    await t.tap(byKey('filter-groups'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g2')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-c1')), findsNothing);
    expect(find.byKey(const ValueKey('conversation-c2')), findsNothing);
    expect(find.byKey(const ValueKey('conversation-g3')), findsNothing);
    final container = ProviderScope.containerOf(t.element(find.byType(SisApp)));
    expect(container.read(chatListGroupsOnlyProvider), isTrue);
  });

  testWidgets('tap All restores all non‑archived rows', (WidgetTester t) async {
    await pumpList(t);
    await t.tap(byKey('filter-groups'));
    await t.pumpAndSettle();
    await t.tap(byKey('filter-all'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g2')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g3')), findsNothing);
    final container = ProviderScope.containerOf(t.element(find.byType(SisApp)));
    expect(container.read(chatListGroupsOnlyProvider), isFalse);
  });

  testWidgets('filter choice survives opening a chat', (WidgetTester t) async {
    await pumpList(t);
    await t.tap(byKey('filter-groups'));
    await t.pumpAndSettle();
    await t.tap(find.text('Trip'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-g2')), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-c1')), findsNothing);
    final container = ProviderScope.containerOf(t.element(find.byType(SisApp)));
    expect(container.read(chatListGroupsOnlyProvider), isTrue);
  });

  testWidgets('pinned groups stay on top when filtered', (
    WidgetTester t,
  ) async {
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(rows(g2Pinned: true)),
      pins: ChatPinFake(pinned: {'g2'}),
    );
    await t.tap(byKey('filter-groups'));
    await t.pumpAndSettle();
    final trip = find.byKey(const ValueKey('conversation-g2'));
    final club = find.byKey(const ValueKey('conversation-g1'));
    expect(t.getTopLeft(trip).dy, lessThan(t.getTopLeft(club).dy));
  });

  testWidgets('no progress indicator after first frame', (
    WidgetTester t,
  ) async {
    await pumpList(t);
    await t.pump(); // first frame
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Turkish filter chip labels', (WidgetTester t) async {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await pumpList(t);
    expect(find.text('Tümü'), findsOneWidget);
    expect(find.text('Gruplar'), findsOneWidget);
  });

  test('l10n strings', () {
    expect(
      l10n.l10nEn.chatUnreadDivider,
      'Unread messages',
      reason: 'English unread divider',
    );
    expect(l10n.l10nEn.listFilterAll, 'All', reason: 'English All filter');
    expect(
      l10n.l10nEn.listFilterGroups,
      'Groups',
      reason: 'English Groups filter',
    );
    expect(
      l10n.l10nTr.chatUnreadDivider,
      'Okunmamış mesajlar',
      reason: 'Turkish unread divider',
    );
    expect(l10n.l10nTr.listFilterAll, 'Tümü', reason: 'Turkish All filter');
    expect(
      l10n.l10nTr.listFilterGroups,
      'Gruplar',
      reason: 'Turkish Groups filter',
    );
  });

  testWidgets('an account change resets the filter to All', (
    WidgetTester t,
  ) async {
    await pumpList(t);
    await t.tap(byKey('filter-groups'));
    await t.pumpAndSettle();
    final container = ProviderScope.containerOf(t.element(find.byType(SisApp)));
    expect(
      container.read(chatListGroupsOnlyProvider),
      isTrue,
      reason: 'Groups filter on before the account change',
    );
    expect(
      find.byKey(const ValueKey('conversation-c1')),
      findsNothing,
      reason: '1:1 chat hidden while filtered',
    );
    // The account changes: sign out, then sign in again (the id goes through null).
    final session = container.read(sessionControllerProvider.notifier);
    await drive(t, session.signOut());
    await drive(t, session.signIn());
    expect(
      container.read(chatListGroupsOnlyProvider),
      isFalse,
      reason: 'filter back to All after the account change',
    );
    expect(
      find.byKey(const ValueKey('conversation-c1')),
      findsOneWidget,
      reason: '1:1 chat visible again',
    );
  });
}

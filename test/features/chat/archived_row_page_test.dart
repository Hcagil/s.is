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
          ...videoOverrides(),
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
  group('archived row page', () {
    testWidgets('nothing archived', (t) async {
      final archive = ChatArchiveFake();
      await pumpList(t, archive: archive);
      expect(
        find.byKey(const ValueKey('archived-chats-row'), skipOffstage: false),
        findsNothing,
      );
      await t.drag(byKey('conversation-list'), const Offset(0, 120));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('archived-chats-row'), skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('c1 archived', (t) async {
      final archive = ChatArchiveFake(archived: {'c1'});
      await pumpList(
        t,
        chat: ChatFake()..conversationsResult = Ok(list(c1Archived: true)),
        archive: archive,
      );
      expect(byKey('conversation-c1'), findsNothing);
      expect(byKey('conversation-c2'), findsOneWidget);

      final rowFinder = find.byKey(
        const ValueKey('archived-chats-row'),
        skipOffstage: false,
      );
      expect(rowFinder, findsOneWidget);

      final listRect = t.getRect(byKey('conversation-list'));
      final rowRect = t.getRect(rowFinder);
      expect(rowRect.bottom, lessThanOrEqualTo(listRect.top + 0.5));

      await t.drag(byKey('conversation-list'), const Offset(0, 120));
      await t.pumpAndSettle();

      final rowRectAfter = t.getRect(rowFinder);
      expect(rowRectAfter.top, greaterThanOrEqualTo(listRect.top - 0.5));
    });

    // A finger pull of [d] px (after the 18 px touch slop), lifted without a fling.
    Future<void> pull(WidgetTester t, double d) async {
      final g = await t.startGesture(t.getCenter(byKey('conversation-c2')));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(Offset(0, (d + 18) / 10));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
    }

    for (final (d, shown) in [(20.0, false), (45.0, true)]) {
      testWidgets('a ${d.toInt()} px pull snaps the row '
          '${shown ? 'open' : 'shut'} (midpoint 28)', (t) async {
        await pumpList(
          t,
          chat: ChatFake()..conversationsResult = Ok(list(c1Archived: true)),
          archive: ChatArchiveFake(archived: {'c1'}),
        );
        final row = find.byKey(
          const ValueKey('archived-chats-row'),
          skipOffstage: false,
        );
        await pull(t, d);
        final top = t.getRect(byKey('conversation-list')).top;
        final r = t.getRect(row);
        if (shown) {
          expect(r.top, greaterThanOrEqualTo(top - 0.5), reason: '$r');
        } else {
          expect(r.bottom, lessThanOrEqualTo(top + 0.5), reason: '$r');
        }
      });
    }

    testWidgets('archived count shows the archived chats with unread', (
      t,
    ) async {
      await pumpList(
        t,
        chat: ChatFake()
          ..conversationsResult = Ok(list(c1Archived: true, c1Unread: 3)),
        archive: ChatArchiveFake(archived: {'c1'}),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('archived-count'), skipOffstage: false),
          matching: find.text('1', skipOffstage: false),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no archived-count when no archived chat is unread', (t) async {
      await pumpList(
        t,
        chat: ChatFake()..conversationsResult = Ok(list(c1Archived: true)),
        archive: ChatArchiveFake(archived: {'c1'}),
      );
      expect(
        find.byKey(const ValueKey('archived-chats-row'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('archived-count'), skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('archived page', (t) async {
      final archive = ChatArchiveFake(archived: {'c1'});
      await pumpList(
        t,
        chat: ChatFake()
          ..conversationsResult = Ok(list(c1Archived: true, c1Unread: 2)),
        archive: archive,
      );

      await t.drag(byKey('conversation-list'), const Offset(0, 120));
      await t.pumpAndSettle();

      await t.tap(byKey('archived-chats-row'));
      await t.pumpAndSettle();

      expect(byKey('archived-chats-page'), findsOneWidget);
      expect(find.text('Archived chats'), findsOneWidget);
      expect(byKey('archived-tile-c1'), findsOneWidget);
      expect(byKey('unread-c1'), findsNothing);
      expect(byKey('archived-tile-c2'), findsNothing);
    });

    testWidgets('unarchive on page', (t) async {
      final archive = ChatArchiveFake(archived: {'c1'});
      await pumpList(
        t,
        chat: ChatFake()..conversationsResult = Ok(list(c1Archived: true)),
        archive: archive,
      );

      await t.drag(byKey('conversation-list'), const Offset(0, 120));
      await t.pumpAndSettle();

      await t.tap(byKey('archived-chats-row'));
      await t.pumpAndSettle();

      // swipe‑commit to unarchive
      final swipe = await t.startGesture(
        t.getCenter(byKey('archive-swipe-c1')),
      );
      for (var i = 0; i < 10; i++) {
        await swipe.moveBy(const Offset(-10, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await t.pumpAndSettle();

      expect(
        archive.calls.map((e) => (e.key, e.value)).toList(),
        equals([('c1', false)]),
      );

      expect(byKey('archived-empty'), findsOneWidget);
      expect(find.text('No archived chats'), findsOneWidget);

      await t.pageBack();
      await t.pumpAndSettle();

      expect(byKey('conversation-c1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('archived-chats-row'), skipOffstage: false),
        findsNothing,
      );
    });
  });
}

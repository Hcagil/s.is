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
import '../../support/mark_fakes.dart';
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

/// Two chats: c1 with Bob, c2 with Cem, each with [unread] messages.
Conversation conv(
  String id,
  Member other,
  int minute, {
  int unread = 0,
  bool marked = false,
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
  );
}

Future<void> pumpList(
  WidgetTester t, {
  required ChatFake chat,
  required MarkFake mark,
}) async {
  final notif = NotificationSettingsFake(
    mutes: const [],
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
          chatArchiveRepositoryProvider.overrideWithValue(ChatArchiveFake()),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          notificationExplainerStoreProvider.overrideWithValue(
            NotificationExplainerStoreFake(shown: true),
          ),
          chatDeleteRepositoryProvider.overrideWithValue(ChatDeleteFake()),
          chatMarkRepositoryProvider.overrideWithValue(mark),
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c1'), findsOneWidget, reason: 'no list');
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

/// The read / unread items sit in the selection bar's overflow menu.
Future<void> openMore(WidgetTester t) async {
  await t.tap(byKey('selection-more'));
  await t.pumpAndSettle();
}

void main() {
  group('chat mark as unread UI', () {
    testWidgets('hand‑marked chat is bolder, no count pill', (t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, marked: true),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpList(t, chat: chat, mark: mark);
      final w1 = weight(t, byKey('conversation-c1'));
      final w2 = weight(t, byKey('conversation-c2'));
      expect(w1, greaterThan(w2));
      expect(byKey('unread-c1'), findsNothing);
    });

    testWidgets('unread chat shows count pill and is bolder', (t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, unread: 2),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpList(t, chat: chat, mark: mark);
      expect(byKey('unread-c1'), findsOneWidget);
      final w1 = weight(t, byKey('conversation-c1'));
      final w2 = weight(t, byKey('conversation-c2'));
      expect(w1, greaterThan(w2));
    });

    testWidgets('select plain read chat, mark as unread', (t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', bob, 1), conv('c2', cem, 2)]);
      final mark = MarkFake();
      await pumpList(t, chat: chat, mark: mark);
      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      await openMore(t);
      expect(byKey('selection-unread'), findsOneWidget);
      await t.tap(byKey('selection-unread'));
      await t.pumpAndSettle();
      expect(mark.calls, ['c1']);
      final w1 = weight(t, byKey('conversation-c1'));
      final w2 = weight(t, byKey('conversation-c2'));
      expect(w1, greaterThan(w2));
      expect(byKey('unread-c1'), findsNothing);
    });

    testWidgets('only unread chats selected: no Mark as unread item', (
      t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, unread: 2),
          conv('c2', cem, 2, unread: 2),
        ]);
      final mark = MarkFake();
      await pumpList(t, chat: chat, mark: mark);
      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      await t.tap(byKey('conversation-c2'));
      await t.pumpAndSettle();
      await openMore(t);
      expect(byKey('selection-read'), findsOneWidget, reason: 'menu not open');
      expect(byKey('selection-unread'), findsNothing);
    });

    testWidgets('hand‑marked chat selected, mark as read', (t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          conv('c1', bob, 1, marked: true),
          conv('c2', cem, 2),
        ]);
      final mark = MarkFake();
      await pumpList(t, chat: chat, mark: mark);
      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      await openMore(t);
      expect(byKey('selection-read'), findsOneWidget);
      await t.tap(byKey('selection-read'));
      await t.pumpAndSettle();
      expect(chat.markedRead, contains('c1'));
      final w1 = weight(t, byKey('conversation-c1'));
      final w2 = weight(t, byKey('conversation-c2'));
      expect(w1, equals(w2));
    });

    testWidgets('mark as unread fails, UI reverts', (t) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', bob, 1), conv('c2', cem, 2)]);
      final mark = MarkFake();
      mark.result = const Err(DeniedFailure());
      await pumpList(t, chat: chat, mark: mark);
      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      await openMore(t);
      await t.tap(byKey('selection-unread'));
      await t.pumpAndSettle();
      final w1 = weight(t, byKey('conversation-c1'));
      final w2 = weight(t, byKey('conversation-c2'));
      expect(w1, equals(w2));
      expect(mark.calls, ['c1']);
      await t.pump(const Duration(seconds: 3)); // the refusal notice's timer
    });
  });
}

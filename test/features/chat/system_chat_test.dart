// The SIS system chat in the app, written from the contract: the list names
// it "SIS"; opened, it has no composer but the line "Only SIS can post here"
// (key composer-system); its header opens a page offering mute only (key
// system-name); it is never offered as a forward target. Conversation keeps
// the flag through its JSON (key isSystem, default false). Reached the way a
// member reaches it: the whole app as main.dart mounts it, fakes only at the
// repository boundaries. Run under TZ=JST-9 like every unit test.
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
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/presentation/whats_new_card.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const sisId = '00000000-0000-0000-0000-00000000515e';

const sis = Conversation(
  id: 's1',
  isSystem: true,
  lastMessage: 'Notifications are grouped now.',
);
const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');
const club = Conversation(id: 'g1', title: 'Club', lastMessage: 'yo');

Message note(String id, String body) => Message(
  id: id,
  conversationId: 's1',
  senderId: sisId,
  body: body,
  createdAt: DateTime.now(),
);

class World {
  World() {
    chat
      ..conversationsResult = const Ok([sis, withBob, club])
      ..membersResult = const Ok([bob])
      ..roster['c1'] = [me, bob]
      ..roster['g1'] = [me, bob];
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2));
  final notif = NotificationSettingsFake();

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(
        const RuntimeConfig(
          supabaseUrl: 'https://x.supabase.co',
          supabasePublishableKey: 'k',
          googleWebClientId: 'c',
        ),
      ),
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
            displayName: 'Maya Kaya',
            tag: 'maya',
            onboardingDone: true,
          ),
        ),
      ),
      notificationSettingsRepositoryProvider.overrideWithValue(notif),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await settleImages(t);
}

Future<void> openChat(WidgetTester t, World w, String id) async {
  await t.pumpWidget(w.app());
  await settle(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
  await t.ensureVisible(byKey('conversation-$id'));
  await t.pump();
  await t.tap(byKey('conversation-$id'));
  await settle(t);
  expect(find.byType(MessageScreen), findsOneWidget);
}

Finder get appBar => find.descendant(
  of: find.byType(MessageScreen),
  matching: find.byType(AppBar),
);

void main() {
  group('Conversation', () {
    test('label is SIS for the system chat', () {
      expect(sis.label, 'SIS');
      expect(const Conversation(id: 'x', isSystem: true).label, 'SIS');
    });

    test('isSystem defaults to false, and to false from JSON without it', () {
      expect(withBob.isSystem, isFalse);
      final json = withBob.toJson()..remove('isSystem');
      expect(Conversation.fromJson(json).isSystem, isFalse);
    });

    test('isSystem travels through JSON under the key isSystem', () {
      expect(sis.toJson()['isSystem'], isTrue);
      expect(withBob.toJson()['isSystem'], isFalse);
      final back = Conversation.fromJson(sis.toJson());
      expect(back.isSystem, isTrue);
      expect(back.label, 'SIS');
    });
  });

  group('system chat', () {
    testWidgets('the list names it SIS', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await settle(t);

      expect(
        find.descendant(
          of: byKey('conversation-s1'),
          matching: find.text('SIS'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('opened, it has no composer, only "Only SIS can post here"', (
      t,
    ) async {
      final w = World();
      w.chat.history['s1'] = [note('n1', 'Notifications are grouped now.')];
      await openChat(t, w, 's1');

      expect(find.text('Notifications are grouped now.'), findsWidgets);
      expect(byKey('composer-system'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('composer-system'),
          matching: find.text('Only SIS can post here'),
        ),
        findsOneWidget,
      );
      expect(byKey('composer-field'), findsNothing);
      expect(byKey('composer-send'), findsNothing);
      expect(byKey('composer-attach'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(MessageScreen),
          matching: find.byType(TextField),
        ),
        findsNothing,
        reason: 'nothing to type into',
      );
    });

    testWidgets('control: an ordinary chat keeps its composer', (t) async {
      final w = World();
      await openChat(t, w, 'c1');

      expect(byKey('composer-field'), findsOneWidget);
      expect(byKey('composer-system'), findsNothing);
    });

    testWidgets('its header opens a page with mute only, and mute mutes the '
        'conversation', (t) async {
      final w = World();
      await openChat(t, w, 's1');

      await t.tap(find.descendant(of: appBar, matching: find.text('SIS')));
      await settle(t);

      expect(find.byType(SystemChatScreen), findsOneWidget);
      expect(byKey('system-name'), findsOneWidget);
      expect(find.byType(PersonScreen), findsNothing);
      expect(find.byType(GroupScreen), findsNothing);
      expect(byKey('mute-tile'), findsOneWidget);
      // Mute only: no tabs of members, media or links, nothing to leave.
      expect(find.byType(Tab), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.textContaining('Leave'), findsNothing);
      expect(find.textContaining('Add'), findsNothing);
      expect(find.textContaining('Delete'), findsNothing);

      await t.tap(byKey('mute-tile'));
      await settle(t);
      await t.tap(byKey('mute-threeDays'));
      await settle(t);

      final (kind, target, until) = w.notif.muteCalls.single;
      expect(kind, MuteKind.conversation);
      expect(target, 's1');
      expect(
        until!.difference(DateTime.now().add(const Duration(days: 3))).abs(),
        lessThan(const Duration(minutes: 1)),
        reason: '3 days was picked',
      );
    });

    testWidgets('it is never offered as a forward target', (t) async {
      final w = World();
      w.chat.history['c1'] = [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: bob.userId,
          body: 'look at this',
          createdAt: DateTime.now(),
        ),
      ];
      await openChat(t, w, 'c1');

      await t.longPress(byKey('message-m1'));
      await settle(t);
      await t.tap(byKey('menu-forward'));
      await settle(t);

      expect(byKey('forward-g1'), findsOneWidget, reason: 'the sheet is open');
      expect(byKey('forward-s1'), findsNothing);
    });
  });
  // Seam: the real message screen renders SIS notes through the What's new
  // cards. FakeUpdate's Play check offers nothing, so the state is idle.
  group("What's new in the SIS chat", () {
    Finder saying(String s) => find.byWidgetPredicate(
      (w) => w is Text && w.data?.toLowerCase() == s.toLowerCase(),
    );
    final versionLine = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').toLowerCase().startsWith('version'),
    );

    testWidgets('a real-format note (no version line) is a plain card', (
      t,
    ) async {
      const body =
          'Scrolling back down reaches the newest messages with photos.\n'
          'One offline notice instead of two.';
      final w = World();
      w.chat.history['s1'] = [note('n1', body)];
      await openChat(t, w, 's1');

      expect(find.byType(WhatsNewCard), findsOneWidget);
      expect(find.text(body), findsOneWidget, reason: 'the whole body');
      expect(versionLine, findsNothing);
      expect(byKey('composer-system'), findsOneWidget);
    });

    testWidgets('a versioned note is a version card with its bullets', (
      t,
    ) async {
      final w = World();
      w.chat.history['s1'] = [
        note('n1', 'Version 0.30\n- Older thing'),
        note('n2', 'v0.31\n- Chats load faster\n* Photos open in place'),
      ];
      await openChat(t, w, 's1');

      expect(find.byType(WhatsNewCard), findsNWidgets(2));
      expect(saying('Version 0.31'), findsOneWidget);
      expect(saying('Version 0.30'), findsOneWidget);
      expect(find.text('Chats load faster'), findsOneWidget);
      expect(find.text('Photos open in place'), findsOneWidget);
      expect(find.textContaining('v0.31'), findsNothing, reason: 'parsed');
      // Idle: nothing to update to, so no card is lit; the chat says so.
      expect(byKey('whats-new-card-new'), findsNothing);
      expect(byKey('whats-new-card-old'), findsNWidgets(2));
      expect(byKey('whats-new-up-to-date'), findsOneWidget);
      expect(find.text("You're up to date"), findsOneWidget);
      expect(byKey('composer-system'), findsOneWidget);
    });

    testWidgets('control: an ordinary chat has no cards and no mark', (
      t,
    ) async {
      final w = World();
      w.chat.history['c1'] = [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: bob.userId,
          body: 'v0.31\n- hi',
          createdAt: DateTime.now(),
        ),
      ];
      await openChat(t, w, 'c1');

      expect(find.byType(WhatsNewCard), findsNothing);
      expect(byKey('whats-new-up-to-date'), findsNothing);
    });
  });
}

// Shared harness for the invite-link widget tests: the real app over fakes.
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
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/application/invite_link_controller.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import './fakes.dart';
import './group_settings_fakes.dart';
import './video_fakes.dart';
import './invite_link_fake.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');

Message m(
  String id,
  String conv,
  String from,
  DateTime at, {
  String body = '',
}) => Message(
  id: id,
  conversationId: conv,
  senderId: from,
  body: body,
  createdAt: at,
);

/// Test world for invite‑related UI tests.
///
/// The world mounts the real app (SisApp) with fakes for all repositories
/// except the invite link repository, which is overridden with an
/// [InviteLinkFake].  It exposes a small API that test files can use to
/// open the group page or the new‑chat page.
class InviteWorld {
  InviteWorld({bool admin = true, bool closed = false}) {
    chat = ChatFake(latency: const Duration(milliseconds: 2), self: 'u1');
    invite = InviteLinkFake(latency: const Duration(milliseconds: 5));
    groups = GroupSettingsFake(latency: Duration.zero);

    // Conversations: only the group g1, possibly closed.
    chat.conversationsResult = Ok([
      Conversation(
        id: 'g1',
        title: 'Club',
        lastMessage: 'yo',
        isClosed: closed,
      ),
    ]);

    // Group roster for g1.
    chat.groupRosters['g1'] = [
      GroupMember(member: me, isAdmin: admin),
      GroupMember(member: bob, isAdmin: !admin),
      GroupMember(member: cem, isAdmin: false),
    ];

    // Members list for g1.
    chat.membersResult = Ok([bob, cem]);

    // Roster for g1.
    chat.roster['g1'] = [me, bob, cem];

    // History for g1: one message from ub.
    chat.history['g1'] = [
      m('gt', 'g1', 'ub', DateTime.utc(2026, 9, 19, 11), body: 'hello'),
    ];

    // Invite link admin status for g1 and g2.
    invite.admins.addAll(['g1', 'g2']);
  }

  /// The chat fake used by the app.
  late final ChatFake chat;

  /// The invite link fake used by the app.
  late final InviteLinkFake invite;

  /// The group settings fake used by the app.
  late final GroupSettingsFake groups;

  /// Mounts the real app with the fakes overridden.
  Widget app() => ProviderScope(
    overrides: [
      ...videoOverrides(),
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
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      groupSettingsRepositoryProvider.overrideWithValue(groups),
      inviteLinkRepositoryProvider.overrideWithValue(invite),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key));

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)));

Future<void> steps(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> settle(WidgetTester t) => steps(t);

Future<void> pumpApp(WidgetTester t, InviteWorld w) async {
  await t.pumpWidget(w.app());
  await settle(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

/// Scrolls the group page until [f] is built (tab content is lazy).
Future<void> reveal(WidgetTester t, Finder f) async {
  for (final dy in [-200.0, 200.0]) {
    for (var i = 0; i < 20 && f.evaluate().isEmpty; i++) {
      final page = find.byType(NestedScrollView);
      if (page.evaluate().isEmpty) return;
      await t.drag(page.first, Offset(0, dy), warnIfMissed: false);
      await settle(t);
    }
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  await reveal(t, byKey(key));
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await settle(t);
}

Future<void> openNewChat(WidgetTester t) => tapKey(t, 'new-chat');

Future<void> openChat(WidgetTester t, String id) async {
  await tapKey(t, 'conversation-$id');
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> openTitle(WidgetTester t) async {
  await t.tap(byKey('conversation-title'));
  await settle(t);
}

/// The group page, from the group chat's title.
Future<void> openGroupPage(WidgetTester t, InviteWorld w) async {
  await pumpApp(t, w);
  await openChat(t, 'g1');
  await openTitle(t);
  expect(find.byType(GroupScreen), findsOneWidget);
}

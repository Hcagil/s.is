import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/account_deletion_controller.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/account_deletion_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/group_settings_fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

class FakeDeletions implements AccountDeletionRepository {
  FakeDeletions(this.gone);
  final Set<String> gone;
  final asked = <String>[];
  @override
  Future<Result<DateTime>> requestDeletion() => throw UnimplementedError();
  @override
  Future<Result<Set<String>>> missingUsers(List<String> ids) async {
    asked.addAll(ids);
    return Ok(ids.where(gone.contains).toSet());
  }
}

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const ghost = Member(userId: 'ux', displayName: '');
const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
final t0 = DateTime.utc(2026, 9, 29, 9);
Message m(String id, String from, int minute, String body) => Message(
  id: id,
  conversationId: 'g1',
  senderId: from,
  body: body,
  createdAt: t0.add(Duration(minutes: minute)),
);

class World {
  World({required Set<String> gone}) : repo = FakeDeletions(gone) {
    chat
      ..conversationsResult = const Ok([
        Conversation(id: 'c1', other: ghost, lastMessage: 'hi'),
        Conversation(id: 'g1', title: 'Club', lastMessage: 'yo'),
      ])
      ..membersResult = const Ok([bob])
      ..roster['c1'] = [me]
      ..groupRosters['g1'] = [
        GroupMember(member: me, isAdmin: true),
        const GroupMember(member: bob, isAdmin: false),
        const GroupMember(member: ghost, isAdmin: false),
      ]
      ..history['g1'] = [
        m('m1', 'uz', 0, 'ghost says hi'),
        m('m2', 'ub', 2, 'bob says hi'),
      ];
  }
  final FakeDeletions repo;
  final chat = ChatFake(latency: const Duration(milliseconds: 2), self: 'u1');
  final groups = GroupSettingsFake(latency: Duration.zero);
  Widget app() => ProviderScope(
    overrides: [
      ...videoOverrides(),
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: me),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      groupSettingsRepositoryProvider.overrideWithValue(groups),
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
      accountDeletionRepositoryProvider.overrideWithValue(repo),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key), skipOffstage: false);
Future<void> drain(WidgetTester t) => t.pump(const Duration(seconds: 30));
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await settle(t);
  await t.pump(const Duration(milliseconds: 500));
}

Future<void> openChat(WidgetTester t, World w, String id) async {
  await t.pumpWidget(w.app());
  await settle(t);
  await tapKey(t, 'conversation-$id');
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> openClub(WidgetTester t, World w) => openChat(t, w, 'g1');
Future<void> clubMembers(WidgetTester t, World w) async {
  await openClub(t, w);
  await t.tap(byKey('conversation-title'));
  await settle(t);
  expect(find.byType(GroupScreen), findsOneWidget);
  await tapKey(t, 'tab-members');
}

final appBar = find.descendant(
  of: find.byType(MessageScreen),
  matching: find.byType(AppBar),
);

void main() {
  final label = l10nEn.deletedAccountName;
  final memberFallback = l10nEn.commonMember;

  group('deleted account label', () {
    testWidgets('1:1 header shows the deleted-account label', (
      WidgetTester t,
    ) async {
      final w = World(gone: {'ux'});
      await openChat(t, w, 'c1');
      expect(
        find.descendant(
          of: appBar,
          matching: find.textContaining(label, findRichText: true),
        ),
        findsWidgets,
      );
      expect(w.repo.asked, contains('ux'));
      await drain(t);
    });

    testWidgets(
      '1:1 header: person not reported deleted does not show the label',
      (WidgetTester t) async {
        final w = World(gone: {});
        await openChat(t, w, 'c1');
        expect(
          find.descendant(
            of: appBar,
            matching: find.textContaining(label, findRichText: true),
          ),
          findsNothing,
        );
        await drain(t);
      },
    );

    testWidgets('members tab: a member with no name shows the deleted label', (
      WidgetTester t,
    ) async {
      final w = World(gone: {'ux'});
      await clubMembers(t, w);
      expect(
        find.descendant(
          of: byKey('group-member-ux'),
          matching: find.textContaining(
            label,
            findRichText: true,
            skipOffstage: false,
          ),
          skipOffstage: false,
        ),
        findsWidgets,
      );
      await drain(t);
    });

    testWidgets('members tab: not reported deleted -> no label', (
      WidgetTester t,
    ) async {
      final w = World(gone: {});
      await clubMembers(t, w);
      expect(
        find.descendant(
          of: byKey('group-member-ux'),
          matching: find.textContaining(
            label,
            findRichText: true,
            skipOffstage: false,
          ),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await drain(t);
    });

    testWidgets('group bubble sender name shows the deleted label', (
      WidgetTester t,
    ) async {
      final w = World(gone: {'uz'});
      await openClub(t, w);
      expect(
        find.descendant(
          of: find.byType(MessageScreen),
          matching: find.textContaining(label, findRichText: true),
        ),
        findsWidgets,
      );
      await drain(t);
    });

    testWidgets(
      'group bubble: sender not reported deleted shows Member, not the label',
      (WidgetTester t) async {
        final w = World(gone: {});
        await openClub(t, w);
        expect(
          find.descendant(
            of: find.byType(MessageScreen),
            matching: find.textContaining(label, findRichText: true),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(MessageScreen),
            matching: find.textContaining(memberFallback, findRichText: true),
          ),
          findsWidgets,
        );
        await drain(t);
      },
    );
  });
}

// Leaving a group, the members tab, admins and event lines (v0.23.0), in the
// app as main.dart mounts it (SisApp, so leftConversationGuardProvider is
// wired the way production wires it), over the shared ChatFake with its
// server-like group roster. Written from docs/DECISIONS.md (2026-09-29) and
// the UI keys the feature publishes, never from the widgets' code.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_event.dart';
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

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');
// Hol left before; she is in nobody's people any more, only in the roster.
const hol = Member(userId: 'uh', displayName: 'Hol Varga', tag: 'hol');
const dee = Member(userId: 'ud', displayName: 'Dee North', tag: 'dee');

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
  World({bool admin = true}) {
    chat
      ..conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Club', lastMessage: 'yo'),
      ])
      ..membersResult = const Ok([bob, cem, dee])
      ..reachable.addAll([bob, cem, dee, hol])
      ..groupRosters['g1'] = [
        GroupMember(member: me, isAdmin: admin),
        GroupMember(member: bob, isAdmin: !admin),
        const GroupMember(member: cem, isAdmin: false),
        const GroupMember(
          member: hol,
          isAdmin: false,
          leftReason: LeftReason.left,
        ),
      ]
      ..history['g1'] = [
        m('mh', 'uh', 0, 'hol was here'),
        m('mb', 'ub', 2, 'bob says hi'),
        m('mc', 'u3', 4, 'cem says yo'),
      ]
      ..events['g1'] = [
        GroupEvent(
          id: 'e1',
          conversationId: 'g1',
          kind: GroupEventKind.left,
          subjectId: 'uh',
          createdAt: t0.add(const Duration(minutes: 1)),
        ),
      ];
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2), self: 'u1');

  Widget app() => ProviderScope(
    overrides: [
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
            displayName: 'Maya Kaya',
            tag: 'maya',
            onboardingDone: true,
          ),
        ),
      ),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

// Rows below the fold of a lazily built list count as offstage for a
// default finder; these are found wherever they are and scrolled to on tap.
Finder byKey(String key) => find.byKey(ValueKey(key), skipOffstage: false);

/// The "Left" section header: the "Left" text that is no row's subtitle.
Finder leftHeader() => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText() == 'Left',
  skipOffstage: false,
);

double top(WidgetTester t, Finder f) => t.getTopLeft(f).dy;

String textOf(Finder f) => find
    .descendant(
      of: f,
      matching: find.byType(RichText, skipOffstage: false),
      matchRoot: true,
      skipOffstage: false,
    )
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join(' ');

/// The colour a name is painted in under [f].
Color? colorOf(WidgetTester t, Finder f, String text) {
  final rt = find
      .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
      .evaluate()
      .map((e) => e.widget as RichText)
      .firstWhere((r) => r.text.toPlainText().contains(text));
  Color? found;
  rt.text.visitChildren((span) {
    if (span.toPlainText().contains(text) && span.style?.color != null) {
      found = span.style!.color;
    }
    return true;
  });
  return found ?? rt.text.style?.color;
}

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)));

/// Lets notices and retries run out before the test ends.
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

Future<void> openClub(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await settle(t);
  await tapKey(t, 'conversation-g1');
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> clubMembers(WidgetTester t, World w) async {
  await openClub(t, w);
  await t.tap(byKey('conversation-title'));
  await settle(t);
  expect(find.byType(GroupScreen), findsOneWidget);
  await tapKey(t, 'tab-members');
}

void main() {
  group('members tab', () {
    testWidgets('admins are marked; an admin gets add, remove and admin '
        'toggles for others but not for herself', (t) async {
      final w = World();
      await clubMembers(t, w);
      expect(textOf(byKey('group-member-u1')), contains('Admin'));
      expect(textOf(byKey('group-member-ub')), isNot(contains('Admin')));
      expect(byKey('add-members'), findsOneWidget);
      for (final id in ['ub', 'u3']) {
        expect(byKey('remove-member-$id'), findsOneWidget, reason: id);
        expect(byKey('toggle-admin-$id'), findsOneWidget, reason: id);
      }
      expect(byKey('remove-member-u1'), findsNothing, reason: 'remove self');
      expect(byKey('remove-member-uh'), findsNothing, reason: 'already gone');
      expect(byKey('toggle-admin-uh'), findsNothing, reason: 'already gone');
      await drain(t);
    });

    testWidgets('an ordinary member sees the admin marked but no admin '
        'action at all', (t) async {
      final w = World(admin: false);
      await clubMembers(t, w);
      expect(textOf(byKey('group-member-ub')), contains('Admin'));
      expect(byKey('add-members'), findsNothing);
      for (final id in ['u1', 'ub', 'u3', 'uh']) {
        expect(byKey('remove-member-$id'), findsNothing, reason: id);
        expect(byKey('toggle-admin-$id'), findsNothing, reason: id);
      }
      expect(byKey('leave-group'), findsOneWidget, reason: 'anyone may leave');
      await drain(t);
    });

    testWidgets('who left is listed apart, under "Left", after everyone '
        'current', (t) async {
      final w = World();
      await clubMembers(t, w);
      final holRow = byKey('group-member-uh');
      expect(holRow, findsOneWidget);
      // A header "Left" sits between everyone current and Hol.
      final headers = leftHeader().evaluate().where((e) {
        final y = (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
        return y > top(t, byKey('group-member-u3')) && y < top(t, holRow);
      });
      expect(headers, hasLength(1), reason: 'no "Left" section header');
      for (final id in ['u1', 'ub', 'u3']) {
        expect(
          top(t, byKey('group-member-$id')),
          lessThan(top(t, holRow)),
          reason: '$id listed among those who left',
        );
      }
      expect(textOf(holRow), contains('Left'), reason: 'how she went');
      await drain(t);
    });

    testWidgets('remove asks the server for exactly that member, and the '
        'list moves them under "Left"', (t) async {
      final w = World();
      await clubMembers(t, w);
      await tapKey(t, 'remove-member-u3');
      expect(w.chat.groupWrites, ['remove:g1:u3']);
      expect(byKey('remove-member-u3'), findsNothing);
      expect(byKey('toggle-admin-u3'), findsNothing);
      expect(textOf(byKey('group-member-u3')), contains('Removed'));
      expect(
        top(t, byKey('group-member-u3')),
        greaterThan(top(t, byKey('group-member-ub'))),
      );
      await drain(t);
    });

    testWidgets('make admin sends isAdmin: true for that member', (t) async {
      final w = World();
      await clubMembers(t, w);
      await tapKey(t, 'toggle-admin-u3');
      expect(w.chat.groupWrites, ['admin:g1:u3:true']);
      expect(textOf(byKey('group-member-u3')), contains('Admin'));
      await drain(t);
    });

    testWidgets('adding: only people not already in, and the "Show old '
        'messages?" choice reaches the server', (t) async {
      final w = World();
      await clubMembers(t, w);
      await tapKey(t, 'add-members');
      expect(find.text('Show old messages?'), findsOneWidget);
      expect(byKey('add-member-ud'), findsOneWidget);
      expect(byKey('add-member-ub'), findsNothing, reason: 'already in');
      await tapKey(t, 'add-member-ud');
      // The choice starts one way; flip it, and the call must say the other.
      final choice = find.ancestor(
        of: find.text('Show old messages?'),
        matching: find.byType(SisSwitchTile),
      );
      expect(choice, findsOneWidget);
      final before = t.widget<SisSwitchTile>(choice).value;
      await t.tap(find.text('Show old messages?'));
      await settle(t);
      expect(t.widget<SisSwitchTile>(choice).value, !before);
      await tapKey(t, 'add-members-confirm');
      expect(w.chat.groupWrites, ['add:g1:ud:${!before}']);
      // And the other way round, in a second add.
      await tapKey(t, 'add-members');
      expect(byKey('add-member-ud'), findsNothing, reason: 'dee is in now');
      await drain(t);
    });
  });

  group('leaving', () {
    testWidgets('cancel keeps you in; confirm leaves, the write box is '
        'replaced and the list shows the group left, greyed', (t) async {
      final w = World();
      await clubMembers(t, w);
      await tapKey(t, 'leave-group');
      expect(find.text('Leave group?'), findsOneWidget);
      await tapKey(t, 'leave-cancel');
      expect(w.chat.groupWrites, isEmpty);

      await tapKey(t, 'leave-group');
      await tapKey(t, 'leave-confirm');
      expect(w.chat.groupWrites, ['leave:g1']);
      expect(find.textContaining('Left the group'), findsOneWidget);

      // Back to the list, however many pages the leave left open: the
      // topmost page's back button each time.
      for (
        var i = 0;
        i < 3 && find.byTooltip('Back').evaluate().isNotEmpty;
        i++
      ) {
        await t.tap(find.byTooltip('Back').last, warnIfMissed: false);
        await t.pump(const Duration(seconds: 1));
        await settle(t);
      }
      expect(byKey('left-g1'), findsOneWidget, reason: 'no left tile');
      await tapKey(t, 'conversation-g1');
      expect(byKey('composer-left'), findsOneWidget);
      expect(byKey('composer-field'), findsNothing);
      expect(find.text('hol was here'), findsOneWidget, reason: 'history');
      await t.pageBack();
      await settle(t);
      expect(byKey('conversation-g1'), findsOneWidget, reason: 'still listed');
      await drain(t);
    });

    testWidgets('a group already left opens read-only', (t) async {
      final w = World();
      w.chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Club', lastMessage: 'yo', hasLeft: true),
      ]);
      await openClub(t, w);
      expect(byKey('composer-left'), findsOneWidget);
      expect(byKey('composer-field'), findsNothing);
      expect(find.text('cem says yo'), findsOneWidget);
      await drain(t);
    });

    testWidgets('unsent messages and the draft go, with one notice', (t) async {
      final w = World();
      w.chat.sendResult = const Err(
        NetworkFailure('No connection', retryable: true),
      );
      await clubMembers(t, w);
      final c = containerOf(t);
      c.read(sendQueueProvider.notifier)
        ..enqueue('g1', body: 'one')
        ..enqueue('g1', body: 'two');
      c.read(draftsProvider.notifier).setText('g1', 'half typed');
      await settle(t);
      expect(c.read(sendQueueProvider)['g1'], hasLength(2), reason: 'fixture');

      await tapKey(t, 'leave-group');
      await tapKey(t, 'leave-confirm');

      expect(c.read(sendQueueProvider)['g1'] ?? const [], isEmpty);
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, isEmpty);
      final notices = find.textContaining('Left the group');
      expect(notices, findsOneWidget, reason: 'exactly one notice');
      expect(textOf(notices), contains('Unsent messages'));
      final sends = w.chat.sent.length;
      await t.pump(const Duration(seconds: 30));
      await settle(t);
      expect(w.chat.sent.length, sends, reason: 'sent after leaving');
      await drain(t);
    });

    testWidgets('removed elsewhere: found on the next list read, the queue '
        'and draft are dropped quietly, and the write box goes', (t) async {
      final w = World();
      w.chat.sendResult = const Err(
        NetworkFailure('No connection', retryable: true),
      );
      await openClub(t, w);
      final c = containerOf(t);
      c.read(sendQueueProvider.notifier).enqueue('g1', body: 'one');
      c.read(draftsProvider.notifier).setText('g1', 'half typed');
      await settle(t);

      w.chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Club', lastMessage: 'yo', hasLeft: true),
      ]);
      unawaited(c.read(conversationListProvider.notifier).refresh());
      await settle(t);

      expect(c.read(sendQueueProvider)['g1'] ?? const [], isEmpty);
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, isEmpty);
      expect(byKey('composer-left'), findsOneWidget);
      expect(find.textContaining('Left the group'), findsNothing);
      await t.pump(const Duration(seconds: 30));
      await settle(t);
      await drain(t);
    });
  });

  group('in the chat', () {
    testWidgets('a departed sender keeps her name, greyed', (t) async {
      // Each person has a tint of their own, so "greyed" is Hol's own name
      // painted differently once she has left than while she was in.
      final w = World();
      await openClub(t, w);
      final holName = byKey('sender-mh');
      expect(textOf(holName), contains('Hol Varga'));
      final departed = colorOf(t, holName, 'Hol Varga');
      await drain(t);

      final stillIn = World();
      stillIn.chat.groupRosters['g1']![3] = const GroupMember(
        member: hol,
        isAdmin: false,
      );
      await t.pumpWidget(const SizedBox());
      await openClub(t, stillIn);
      final current = colorOf(t, byKey('sender-mh'), 'Hol Varga');
      expect(departed, isNotNull);
      expect(
        departed,
        isNot(current),
        reason: 'the departed name is not greyed',
      );
      await drain(t);
    });

    testWidgets('an admin sees the event line, naming who left from the '
        'roster, in its place in time', (t) async {
      final w = World();
      await openClub(t, w);
      expect(byKey('event-e1'), findsOneWidget);
      expect(textOf(byKey('event-e1')), contains('Hol Varga left'));
      expect(textOf(byKey('event-e1')), isNot(contains('Someone')));
      final y = t.getTopLeft(byKey('event-e1')).dy;
      expect(t.getTopLeft(find.text('hol was here')).dy, lessThan(y));
      expect(t.getTopLeft(find.text('bob says hi')).dy, greaterThan(y));
      await drain(t);
    });

    testWidgets('an ordinary member sees no event line', (t) async {
      final w = World(admin: false);
      await openClub(t, w);
      expect(find.byKey(const ValueKey('event-e1')), findsNothing);
      expect(find.textContaining('left'), findsNothing);
      await drain(t);
    });
  });
}

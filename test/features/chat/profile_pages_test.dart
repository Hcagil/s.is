// Person and group pages, written from the contract and reached the way a
// member reaches them: the whole app as main.dart mounts it, a conversation
// tapped in the list, its title tapped. Fakes stand only at the repository
// boundaries; every provider, controller and widget between them is the
// production one. Run under TZ=JST-9 like every unit test: the link rows show
// a date, and a date shown in UTC is a different day here.
import 'dart:io';

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
import 'package:sis/features/chat/domain/initials.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/domain/last_seen.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');
const club = Conversation(id: 'g1', title: 'Club', lastMessage: 'yo');

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Message m(
  String id,
  String conversation,
  String from,
  DateTime at, {
  String body = '',
  String? photo,
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: at,
  attachmentPath: photo,
);

/// 20:00 UTC on the 21st is 05:00 on the 22nd in JST: the date a member in
/// Tokyo must see on the link row is the 22nd.
final lateUtc = DateTime.utc(2026, 9, 21, 20);

class World {
  World() {
    chat
      ..conversationsResult = const Ok([withBob, club])
      ..membersResult = const Ok([bob, cem])
      ..roster['c1'] = [me, bob]
      ..roster['g1'] = [me, bob, cem]
      ..history['c1'] = [
        m('p1', 'c1', 'ub', DateTime.utc(2026, 9, 20, 10), photo: 'c1/1.png'),
        m(
          'l1',
          'c1',
          'u1',
          DateTime.utc(2026, 9, 20, 11),
          body: 'read https://docs.example/a',
        ),
        m(
          'p2',
          'c1',
          'u1',
          DateTime.utc(2026, 9, 20, 12),
          photo: 'c1/2.png',
          body: 'more at www.pics.example/2',
        ),
        m('t1', 'c1', 'ub', DateTime.utc(2026, 9, 20, 13), body: 'plain text'),
        m(
          'l2',
          'c1',
          'ub',
          lateUtc,
          body: 'two: https://one.example/x and http://two.example',
        ),
      ]
      ..history['g1'] = [
        m('gp', 'g1', 'u3', DateTime.utc(2026, 9, 19, 9), photo: 'g1/1.png'),
        m(
          'gl',
          'g1',
          'u3',
          DateTime.utc(2026, 9, 19, 10),
          body: 'https://club.example/meet',
        ),
        m('gt', 'g1', 'u1', DateTime.utc(2026, 9, 19, 11), body: 'club hello'),
      ];
    for (final p in ['c1/1.png', 'c1/2.png', 'g1/1.png']) {
      chat.store(p);
    }
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2));
  final presence = PresenceFake();
  final opener = LinkOpenerFake();
  final profile = ProfileFake(
    profile: const OwnProfile(
      userId: 'u1',
      displayName: 'Maya Kaya',
      tag: 'maya',
      onboardingDone: true,
    ),
  );

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: me),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(presence),
      profileRepositoryProvider.overrideWithValue(profile),
      linkOpenerProvider.overrideWithValue(opener),
      attachmentSourceProvider.overrideWithValue(PickerFake.cancels()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key));

/// Everything readable under [f], joined.
String textOf(Finder f) => find
    .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join(' ');

/// Every single text run under [f], one per widget.
List<String> textsOf(Finder f) => [
  for (final e
      in find
          .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
          .evaluate())
    (e.widget as RichText).text.toPlainText().trim(),
];

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(SisApp)));

String? openId(WidgetTester t) => containerOf(t).read(openConversationProvider);

Future<void> steps(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> settle(WidgetTester t) async {
  await steps(t);
  await settleImages(t);
}

Future<void> pumpApp(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await settle(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await settle(t);
}

Future<void> openChat(WidgetTester t, String id) async {
  await tapKey(t, 'conversation-$id');
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> openTitle(WidgetTester t) async {
  await t.tap(byKey('conversation-title'));
  await settle(t);
}

Future<void> back(WidgetTester t) async {
  await t.pageBack();
  await settle(t);
}

/// Bob's page as a 1:1 reaches it: the list, the chat, the title.
Future<void> bobFromChat(WidgetTester t, World w) async {
  await pumpApp(t, w);
  await openChat(t, 'c1');
  await openTitle(t);
  expect(find.byType(PersonScreen), findsOneWidget);
}

/// The group page, from the group chat's title.
Future<void> clubPage(WidgetTester t, World w) async {
  await pumpApp(t, w);
  await openChat(t, 'g1');
  await openTitle(t);
  expect(find.byType(GroupScreen), findsOneWidget);
}

/// A member's page from the group's member list.
Future<void> memberFromGroup(WidgetTester t, World w, String userId) async {
  await clubPage(t, w);
  await tapKey(t, 'group-member-$userId');
  expect(find.byType(PersonScreen), findsOneWidget);
}

/// The background colour an avatar paints behind [initials] under [root].
Color tintOf(WidgetTester t, Finder root, String initials) {
  final text = find.descendant(of: root, matching: find.text(initials));
  expect(text, findsWidgets, reason: 'no avatar "$initials" under $root');
  Color? found;
  t.element(text.first).visitAncestorElements((e) {
    final w = e.widget;
    Color? c;
    if (w is CircleAvatar) {
      c = w.backgroundColor;
    } else if (w is DecoratedBox && w.decoration is BoxDecoration) {
      c = (w.decoration as BoxDecoration).color;
    } else if (w is Container) {
      c = w.color;
    } else if (w is Material && w.type != MaterialType.transparency) {
      c = w.color;
    } else if (w is Ink && w.decoration is BoxDecoration) {
      c = (w.decoration as BoxDecoration).color;
    }
    if (c == null) return true;
    found = c;
    return false;
  });
  expect(found, isNotNull, reason: 'no painted avatar behind "$initials"');
  return found!;
}

/// Whether anything under [root] is painted in the brand colour -- the
/// online dot. Relative by design: an online row has one, an offline row not.
bool hasBrandDot(WidgetTester t, Finder root) {
  final brand = Theme.of(t.element(root)).colorScheme.primary;
  bool paints(Decoration? d) =>
      d is BoxDecoration &&
      (d.color == brand || (d.gradient?.colors.contains(brand) ?? false));
  return find
      .descendant(
        of: root,
        matching: find.byWidgetPredicate(
          (w) =>
              (w is DecoratedBox && paints(w.decoration)) ||
              (w is Container && (w.color == brand || paints(w.decoration))) ||
              (w is CircleAvatar && w.backgroundColor == brand),
        ),
      )
      .evaluate()
      .isNotEmpty;
}

/// The tab body currently on screen.
Finder get tabBody => find.byType(TabBarView);

void main() {
  setUpAll(() => HttpOverrides.global = ImageServer());

  group('entry points', () {
    testWidgets('a 1:1 title opens the person, without a Message button', (
      t,
    ) async {
      final w = World();
      await bobFromChat(t, w);
      expect(find.byType(GroupScreen), findsNothing);
      expect(byKey('person-message'), findsNothing);
      expect(textOf(byKey('person-name')), contains('Bob Stone'));
    });

    testWidgets('a group title opens the group page', (t) async {
      final w = World();
      await clubPage(t, w);
      expect(find.byType(PersonScreen), findsNothing);
      expect(textOf(byKey('group-name')).trim(), 'Club');
    });
  });

  group('person page', () {
    testWidgets('name, @tag and initials come from the member list', (t) async {
      final w = World();
      await bobFromChat(t, w);
      expect(textOf(byKey('person-name')).trim(), 'Bob Stone');
      expect(textOf(byKey('person-tag')).trim(), '@bobby');
      expect(
        find.descendant(
          of: find.byType(PersonScreen),
          matching: find.text(initialsOf('Bob Stone')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('before the member list loads it shows the fallback name, '
        'then the loaded one', (t) async {
      final w = World()
        ..chat.conversationsResult = const Ok([
          Conversation(
            id: 'c1',
            other: Member(userId: 'ub', displayName: 'Bob'),
            lastMessage: 'hi',
          ),
          club,
        ])
        ..chat.holdPeople();
      await pumpApp(t, w);
      await openChat(t, 'c1');
      await openTitle(t);
      expect(textOf(byKey('person-name')).trim(), 'Bob');
      w.chat.releasePeople();
      await settle(t);
      expect(textOf(byKey('person-name')).trim(), 'Bob Stone');
      expect(textOf(byKey('person-tag')).trim(), '@bobby');
    });

    testWidgets('status reads "online" while they are online', (t) async {
      final w = World()
        ..presence.lastSeen['ub'] = DateTime(2020, 1, 2, 3, 4)
        ..presence.setOthersOnline({'ub'});
      await bobFromChat(t, w);
      expect(textOf(byKey('person-status')).trim(), 'online');
    });

    testWidgets('status is the last-seen label when offline', (t) async {
      final at = DateTime(2020, 1, 2, 3, 4);
      final w = World()..presence.lastSeen['ub'] = at;
      await bobFromChat(t, w);
      expect(
        textOf(byKey('person-status')).trim(),
        lastSeenLabel(at, DateTime.now()),
      );
    });

    testWidgets('no status line at all when neither is known', (t) async {
      final w = World();
      await bobFromChat(t, w);
      expect(byKey('person-status'), findsNothing);
    });

    testWidgets('media: newest first from the 1:1; a tap opens the viewer on '
        'that photo with the grid\'s paths', (t) async {
      final w = World();
      await bobFromChat(t, w);
      await tapKey(t, 'tab-media');
      expect(byKey('media-grid'), findsOneWidget);
      final tiles = [
        for (final e
            in find
                .descendant(
                  of: byKey('media-grid'),
                  matching: find.byWidgetPredicate(
                    (x) =>
                        x.key is ValueKey<String> &&
                        (x.key! as ValueKey<String>).value.startsWith('media-'),
                  ),
                )
                .evaluate())
          (e.widget.key! as ValueKey<String>).value.substring(6),
      ];
      expect(tiles, ['c1/2.png', 'c1/1.png']);
      expect(w.chat.calls, contains('sharedMedia:c1'));
      expect(w.chat.calls, isNot(contains('sharedMedia:g1')));

      await tapKey(t, 'media-c1/1.png');
      final viewer = t.widget<PhotoViewer>(find.byType(PhotoViewer));
      expect(viewer.paths, ['c1/2.png', 'c1/1.png']);
      expect(viewer.initialIndex, 1);
    });

    testWidgets('links: one row per link, newest first, with host, address, '
        'sender and the local date', (t) async {
      final w = World();
      await bobFromChat(t, w);
      await tapKey(t, 'tab-links');
      expect(w.chat.calls, contains('sharedLinks:c1'));

      final first = byKey('link-0');
      expect(textsOf(first), contains('one.example'), reason: 'the host');
      expect(textOf(first), contains('https://one.example/x'));
      expect(textOf(first), contains('Bob Stone'));
      expect(textOf(first), isNot(contains('You')));
      // lateUtc is the 21st in UTC and the 22nd in JST.
      final row = textOf(first);
      expect(
        RegExp(r'22\.09|22/09|Sep 22|22 Sep|2026-09-22|09/22').hasMatch(row),
        isTrue,
        reason: 'no local (JST) date in "$row"',
      );
      expect(
        RegExp(r'21\.09|21/09|Sep 21|21 Sep|2026-09-21|09/21').hasMatch(row),
        isFalse,
        reason: 'the UTC date leaked into "$row"',
      );

      // Two links in one message are two rows.
      expect(textOf(byKey('link-1')), contains('http://two.example'));
      expect(textsOf(byKey('link-1')), contains('two.example'));

      await t.scrollUntilVisible(
        byKey('link-3'),
        100,
        scrollable: find
            .descendant(of: tabBody, matching: find.byType(Scrollable))
            .last,
      );
      expect(textOf(byKey('link-2')), contains('www.pics.example/2'));
      expect(textOf(byKey('link-2')), contains('You'));
      expect(textOf(byKey('link-3')), contains('https://docs.example/a'));
      expect(textOf(byKey('link-3')), contains('You'));
      expect(byKey('link-4'), findsNothing);
    });

    testWidgets('tapping a link row opens it', (t) async {
      final w = World();
      await bobFromChat(t, w);
      await tapKey(t, 'tab-links');
      await tapKey(t, 'link-0');
      expect(w.opener.opened, [Uri.parse('https://one.example/x')]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a link nothing can open says so', (t) async {
      final w = World()..opener.opens = false;
      await bobFromChat(t, w);
      await tapKey(t, 'tab-links');
      await tapKey(t, 'link-1');
      expect(w.opener.opened, [Uri.parse('http://two.example')]);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Could not open two.example'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('media and links show a spinner while loading', (t) async {
      final w = World();
      await bobFromChat(t, w);
      w.chat.holdShared();
      // A fresh page: the reads start now and stay in flight.
      await back(t);
      await t.tap(byKey('conversation-title'));
      await steps(t);
      await t.tap(byKey('tab-media'));
      await steps(t);
      expect(
        find.descendant(
          of: tabBody,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsWidgets,
      );
      expect(byKey('media-grid'), findsNothing);

      await t.tap(byKey('tab-links'));
      await steps(t);
      expect(
        find.descendant(
          of: tabBody,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsWidgets,
      );
      expect(byKey('link-0'), findsNothing);

      w.chat.releaseShared();
      await settle(t);
      expect(byKey('link-0'), findsOneWidget);
      await tapKey(t, 'tab-media');
      expect(byKey('media-grid'), findsOneWidget);
    });

    testWidgets('a failed media read shows its reason', (t) async {
      final w = World()
        ..chat.sharedMediaResult = const Err(
          NetworkFailure('photos are out of reach'),
        );
      await bobFromChat(t, w);
      await tapKey(t, 'tab-media');
      expect(find.textContaining('photos are out of reach'), findsOneWidget);
      expect(byKey('media-grid'), findsNothing);
    });

    testWidgets('a failed links read shows its reason', (t) async {
      final w = World()
        ..chat.sharedLinksResult = const Err(
          NetworkFailure('links are out of reach'),
        );
      await bobFromChat(t, w);
      await tapKey(t, 'tab-links');
      expect(find.textContaining('links are out of reach'), findsOneWidget);
      expect(byKey('link-0'), findsNothing);
    });

    testWidgets('with no 1:1 yet: empty tabs, and no chat is created by '
        'looking', (t) async {
      final w = World();
      await clubPage(t, w);
      final before = w.chat.calls.length;
      await tapKey(t, 'group-member-u3');
      expect(find.byType(PersonScreen), findsOneWidget);
      await tapKey(t, 'tab-media');
      expect(find.text('No photos shared yet'), findsOneWidget);
      expect(byKey('media-g1/1.png'), findsNothing, reason: 'group media');
      await tapKey(t, 'tab-links');
      expect(find.text('No links shared yet'), findsOneWidget);
      expect(byKey('link-0'), findsNothing);
      expect(w.chat.started, isEmpty, reason: 'viewing created a chat');
      final after = w.chat.calls.sublist(before);
      expect(
        after.where((c) => c.startsWith('shared')),
        isEmpty,
        reason: 'the page read another conversation\'s media: $after',
      );
    });
  });

  group('Message button', () {
    testWidgets('opens the existing 1:1, without starting one', (t) async {
      final w = World();
      await memberFromGroup(t, w, 'ub');
      await tapKey(t, 'person-message');
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(openId(t), 'c1');
      expect(w.chat.started, isEmpty);
      expect(find.textContaining('two: https://one.example/x'), findsWidgets);
    });

    testWidgets('with no 1:1 yet it starts one and opens it', (t) async {
      final w = World()..chat.startResult = const Ok('c-cem');
      await memberFromGroup(t, w, 'u3');
      await tapKey(t, 'person-message');
      expect(w.chat.started, ['u3']);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(openId(t), 'c-cem');
    });

    testWidgets('a failure to start shows its reason and stays put', (t) async {
      final w = World()
        ..chat.startResult = const Err(
          ProviderFailure('Cem cannot be reached'),
        );
      await memberFromGroup(t, w, 'u3');
      await tapKey(t, 'person-message');
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('Cem cannot be reached'),
        ),
        findsOneWidget,
      );
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(openId(t), 'g1', reason: 'the group is still the open chat');
    });
  });

  group('group page', () {
    testWidgets('name and "N members"', (t) async {
      final w = World();
      await clubPage(t, w);
      expect(textOf(byKey('group-name')).trim(), 'Club');
      expect(textOf(byKey('group-count')).trim(), '3 members');
    });

    testWidgets('"1 member" when you are alone in it', (t) async {
      final w = World()..chat.roster['g1'] = [me];
      await clubPage(t, w);
      expect(textOf(byKey('group-count')).trim(), '1 member');
    });

    testWidgets('members: everyone keyed, you marked and inert, others '
        'open their page with a Message button', (t) async {
      final w = World();
      await clubPage(t, w);
      await tapKey(t, 'tab-members');
      for (final id in ['u1', 'ub', 'u3']) {
        expect(byKey('group-member-$id'), findsOneWidget);
      }
      expect(textOf(byKey('group-member-u1')), contains('Maya Kaya (you)'));
      expect(textOf(byKey('group-member-ub')), isNot(contains('(you)')));

      await tapKey(t, 'group-member-u1');
      expect(find.byType(PersonScreen), findsNothing, reason: 'you are inert');
      expect(find.byType(GroupScreen), findsOneWidget);

      await tapKey(t, 'group-member-ub');
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(textOf(byKey('person-name')).trim(), 'Bob Stone');
      expect(byKey('person-message'), findsOneWidget);
    });

    testWidgets('online members carry the brand dot, others not', (t) async {
      final w = World()..presence.setOthersOnline({'ub'});
      await clubPage(t, w);
      await tapKey(t, 'tab-members');
      expect(hasBrandDot(t, byKey('group-member-ub')), isTrue);
      expect(hasBrandDot(t, byKey('group-member-u3')), isFalse);

      w.presence.setOthersOnline({'u3'});
      await settle(t);
      expect(hasBrandDot(t, byKey('group-member-ub')), isFalse);
      expect(hasBrandDot(t, byKey('group-member-u3')), isTrue);
    });

    testWidgets('a failed member read shows its reason', (t) async {
      final w = World()
        ..chat.conversationMembersResult = const Err(
          NetworkFailure('members are out of reach'),
        );
      await clubPage(t, w);
      await tapKey(t, 'tab-members');
      expect(find.textContaining('members are out of reach'), findsWidgets);
      expect(byKey('group-member-ub'), findsNothing);
    });

    testWidgets('media and links come from the group', (t) async {
      final w = World();
      await clubPage(t, w);
      await tapKey(t, 'tab-media');
      expect(byKey('media-g1/1.png'), findsOneWidget);
      expect(byKey('media-c1/1.png'), findsNothing);
      await tapKey(t, 'media-g1/1.png');
      final viewer = t.widget<PhotoViewer>(find.byType(PhotoViewer));
      expect(viewer.paths, ['g1/1.png']);
      expect(viewer.initialIndex, 0);
      await back(t);

      await tapKey(t, 'tab-links');
      expect(textsOf(byKey('link-0')), contains('club.example'));
      expect(textOf(byKey('link-0')), contains('Cem Ay'));
      expect(byKey('link-1'), findsNothing);
    });
  });

  group('navigation', () {
    testWidgets('group chat -> page -> member -> Message -> back x3: the '
        'group chat is open again and still live', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openChat(t, 'g1');
      expect(openId(t), 'g1');
      await openTitle(t);
      await tapKey(t, 'group-member-ub');
      await tapKey(t, 'person-message');
      expect(openId(t), 'c1');
      expect(find.textContaining('plain text'), findsOneWidget);

      await back(t);
      expect(find.byType(PersonScreen), findsOneWidget);
      await back(t);
      expect(find.byType(GroupScreen), findsOneWidget);
      await back(t);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(openId(t), 'g1', reason: 'the group chat lost its conversation');
      expect(find.textContaining('club hello'), findsOneWidget);
      expect(find.textContaining('plain text'), findsNothing);

      w.chat.deliver(
        m('live', 'g1', 'u3', DateTime.now().toUtc(), body: 'still here?'),
      );
      await settle(t);
      expect(find.text('still here?'), findsOneWidget);

      await back(t);
      expect(openId(t), isNull, reason: 'leaving to the list clears it');
    });

    testWidgets('leaving a chat opened from the list clears the open one', (
      t,
    ) async {
      final w = World();
      await pumpApp(t, w);
      await openChat(t, 'c1');
      expect(openId(t), 'c1');
      await back(t);
      expect(find.byType(MessageScreen), findsNothing);
      expect(openId(t), isNull);
    });
  });

  testWidgets('a person keeps one tint: list, picker, group, page, settings', (
    t,
  ) async {
    final w = World();
    await pumpApp(t, w);
    final bs = initialsOf(bob.displayName);
    final mk = initialsOf(me.displayName);
    final inList = tintOf(t, byKey('conversation-c1'), bs);

    await t.tap(find.text('New chat'));
    await settle(t);
    final inPicker = tintOf(t, byKey('member-ub'), bs);
    Navigator.of(t.element(byKey('member-ub'))).pop();
    await settle(t);

    await openChat(t, 'g1');
    await openTitle(t);
    await tapKey(t, 'tab-members');
    final inGroup = tintOf(t, byKey('group-member-ub'), bs);
    final meInGroup = tintOf(t, byKey('group-member-u1'), mk);
    await tapKey(t, 'group-member-ub');
    final onPage = tintOf(t, find.byType(PersonScreen), bs);

    expect(inPicker, inList, reason: 'picker');
    expect(inGroup, inList, reason: 'group members');
    expect(onPage, inList, reason: 'person page');

    Navigator.of(t.element(find.byType(PersonScreen)))
        .popUntil((r) => r.isFirst);
    await settle(t);
    await tapKey(t, 'home-settings');
    expect(find.byType(SettingsScreen), findsOneWidget);
    final meInSettings = tintOf(t, byKey('settings-profile'), mk);
    expect(meInSettings, meInGroup, reason: 'settings card vs group row');
    // Guards the comparisons above against a palette of one colour. Bob's
    // id is chosen so his tint differs from Maya's under any seeding by id.
    expect(meInGroup, isNot(inGroup), reason: 'two people, one colour');
  });
}

// Person and group pages, written from the contract and reached the way a
// member reaches them: the whole app as main.dart mounts it, a conversation
// tapped in the list, its title tapped. Fakes stand only at the repository
// boundaries; every provider, controller and widget between them is the
// production one. Run under TZ=JST-9 like every unit test: the link rows show
// a date, and a date shown in UTC is a different day here.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/app/settings_row.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/group_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/group_settings.dart';
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/initials.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/presentation/last_seen_text.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/group_settings_fakes.dart';
import '../../support/l10n.dart';
import '../../support/sis_ui.dart';

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
  World({
    String? self,
    this.extra = const [],
    GroupSettings settings = const GroupSettings(),
  }) : chat = ChatFake(latency: const Duration(milliseconds: 2), self: self) {
    chat
      ..conversationsResult = Ok([
        withBob,
        Conversation(
          id: club.id,
          title: club.title,
          lastMessage: club.lastMessage,
          settings: settings,
        ),
      ])
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

  final ChatFake chat;
  late final groups = GroupSettingsFake(
    onDeleted: (id) {
      if (chat.conversationsResult case Ok(:final value)) {
        chat.conversationsResult = Ok([
          for (final c in value)
            if (c.id != id) c,
        ]);
      }
    },
  );

  /// Overrides added after the production ones.
  final List<Override> extra;
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
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      groupSettingsRepositoryProvider.overrideWithValue(groups),
      ...extra,
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

/// Scrolls the page up, then down, until [f] is built. The group page is a
/// NestedScrollView: a tab's content is not built while the header fills
/// the screen, so ensureVisible alone cannot find it.
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

Future<void> openChat(WidgetTester t, String id) async {
  await tapKey(t, 'conversation-$id');
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> openTitle(WidgetTester t) async {
  await t.tap(byKey('conversation-title'));
  await settle(t);
}

/// The top route's back button. The photo viewer is a non-opaque route: the
/// screen behind it stays built, with its own back button, under the viewer.
Future<void> back(WidgetTester t) async {
  await t.tap(find.byType(BackButton).hitTestable().first);
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
        lastSeenText(l10nEn, at, DateTime.now()),
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
      expect(notice, findsNothing);
    });

    testWidgets('a link nothing can open says so', (t) async {
      final w = World()..opener.opens = false;
      await bobFromChat(t, w);
      await tapKey(t, 'tab-links');
      await tapKey(t, 'link-1');
      expect(w.opener.opened, [Uri.parse('http://two.example')]);
      expect(
        find.descendant(
          of: notice,
          matching: find.text('Could not open two.example'),
        ),
        findsOneWidget,
      );
      await drainNotice(t);
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
      expect(find.descendant(of: tabBody, matching: sisWait), findsWidgets);
      expect(byKey('media-grid'), findsNothing);

      await t.tap(byKey('tab-links'));
      await steps(t);
      expect(find.descendant(of: tabBody, matching: sisWait), findsWidgets);
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
          of: notice,
          matching: find.textContaining('Cem cannot be reached'),
        ),
        findsOneWidget,
      );
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(openId(t), 'g1', reason: 'the group is still the open chat');
      await drainNotice(t);
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

  testWidgets(
    'a person keeps one tint outside groups: list, picker, page; a group member wears their group colour',
    (t) async {
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
      final dark =
          Theme.of(t.element(byKey('group-member-ub'))).brightness ==
          Brightness.dark;
      await tapKey(t, 'group-member-ub');
      final onPage = tintOf(t, find.byType(PersonScreen), bs);

      expect(inPicker, inList, reason: 'picker');
      expect(onPage, inList, reason: 'person page');
      // 0.30.7: inside a group a person wears their group colour (slot in
      // joining order: Maya 0, Bob 1), the colour their name has in the chat.
      // (The avatar washes its colour like every tint; the hue is the slot's.)
      Color opaque(Color c) => c.withValues(alpha: 1);
      expect(opaque(inGroup), Color(groupColorArgb(1, dark: dark)));
      expect(opaque(meInGroup), Color(groupColorArgb(0, dark: dark)));

      Navigator.of(t.element(find.byType(PersonScreen)))
          .popUntil((r) => r.isFirst);
      await settle(t);
      await tapKey(t, 'home-settings');
      expect(find.byType(SettingsScreen), findsOneWidget);
      final meInSettings = tintOf(t, byKey('settings-profile'), mk);
      // Guards the comparisons above against a palette of one colour. Bob's
      // id is chosen so his tint differs from Maya's under any seeding by id.
      expect(meInSettings, isNot(inList), reason: 'two people, one colour');
      expect(
        meInSettings,
        isNot(meInGroup),
        reason: 'outside the group: own tint',
      );
    },
  );

  // Update 1 slice 8: the group page's leave card, greyed options and rows.
  group('leave', () {
    /// Club with [me] as an admin (or not) beside bob and cem; when [me] is
    /// not an admin, bob is, so the group always has one.
    World clubWith({required bool admin, List<Override> extra = const []}) {
      final w = World(self: 'u1', extra: extra);
      w.chat.groupRosters['g1'] = [
        GroupMember(member: me, isAdmin: admin),
        GroupMember(member: bob, isAdmin: !admin, colorSlot: 1),
        const GroupMember(member: cem, isAdmin: false, colorSlot: 2),
      ];
      return w;
    }

    Future<void> openCard(WidgetTester t) async {
      await tapKey(t, 'leave-group');
      expect(byKey('leave-card'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing, reason: 'a dialog');
      expect(byKey('leave-confirm'), findsOneWidget);
      expect(byKey('leave-cancel'), findsOneWidget);
    }

    for (final admin in [false, true]) {
      final who = admin ? 'an admin' : 'a member';

      testWidgets('$who: cancel closes the card and changes nothing', (
        t,
      ) async {
        final w = clubWith(admin: admin);
        await clubPage(t, w);
        await openCard(t);
        await tapKey(t, 'leave-cancel');
        expect(byKey('leave-card'), findsNothing);
        expect(find.byType(GroupScreen), findsOneWidget);
        expect(w.chat.groupWrites, isEmpty);
        expect(notice, findsNothing);
      });

      testWidgets('$who: confirm leaves through the real controller, says '
          '"Left the group" and pops the page', (t) async {
        final w = clubWith(admin: admin);
        await clubPage(t, w);
        await openCard(t);
        await t.tap(byKey('leave-confirm'));
        await settle(t);
        expect(w.chat.groupWrites, ['leave:g1']);
        expect(find.byType(GroupScreen), findsNothing, reason: 'not popped');
        expect(byKey('leave-card'), findsNothing);
        expect(t.widgetList<SisNotice>(notice).map((n) => n.message), [
          'Left the group',
        ]);
        await drainNotice(t);
      });
    }

    for (final unsent in [true, false]) {
      testWidgets('the notice follows leave\'s bool: $unsent', (t) async {
        late _LeaveSpy spy;
        final w = clubWith(
          admin: false,
          extra: [
            groupControllerProvider.overrideWith(
              (ref) => spy = _LeaveSpy(ref, unsent),
            ),
          ],
        );
        await clubPage(t, w);
        await openCard(t);
        await t.tap(byKey('leave-confirm'));
        await settle(t);
        expect(spy.left, ['g1']);
        expect(t.widgetList<SisNotice>(notice).map((n) => n.message), [
          unsent
              ? 'Left the group. Unsent messages weren\'t sent.'
              : 'Left the group',
        ]);
        expect(find.byType(GroupScreen), findsNothing);
        await drainNotice(t);
      });
    }
  });

  // Update 2: the Group settings switches and delete-for-everyone.
  group('group settings', () {
    World clubWith({
      required bool admin,
      GroupSettings settings = const GroupSettings(),
    }) {
      final w = World(self: 'u1', settings: settings);
      w.chat.groupRosters['g1'] = [
        GroupMember(member: me, isAdmin: admin),
        GroupMember(member: bob, isAdmin: !admin, colorSlot: 1),
        const GroupMember(member: cem, isAdmin: false, colorSlot: 2),
      ];
      return w;
    }

    const keys = ['setting-pickswitch', 'setting-addsw', 'setting-histsw'];

    /// (value, enabled) of the switch under row [key], Material or own,
    /// wherever it is on the page.
    (bool, bool) switchOf(WidgetTester t, String key) {
      final w = t.widget(
        find.descendant(
          of: find.byKey(ValueKey(key), skipOffstage: false),
          matching: find.byWidgetPredicate(
            (w) => w is Switch || w is SisSwitch,
            skipOffstage: false,
          ),
          matchRoot: true,
          skipOffstage: false,
        ),
      );
      return w is SisSwitch
          ? (w.value, w.onChanged != null)
          : ((w as Switch).value, w.onChanged != null);
    }

    List<bool> values(WidgetTester t) => [
      for (final k in keys) switchOf(t, k).$1,
    ];

    // Not the defaults, so a value read from anywhere but the group shows.
    const odd = GroupSettings(
      membersCanSetAvatar: true,
      membersCanAdd: false,
      newMembersSeeHistory: false,
    );

    testWidgets('a member sees the group\'s values greyed; tapping them '
        'changes nothing and asks the server nothing', (t) async {
      final w = clubWith(admin: false, settings: odd);
      await clubPage(t, w);
      await reveal(t, byKey('setting-pickswitch'));
      expect(values(t), [true, false, false]);
      for (final k in keys) {
        expect(switchOf(t, k).$2, isFalse, reason: '$k is not greyed');
      }
      for (final k in keys) {
        await reveal(t, byKey(k));
        await t.ensureVisible(byKey(k));
        await t.pump();
        await t.tap(byKey(k), warnIfMissed: false);
        await settle(t);
        await reveal(t, byKey('setting-pickswitch'));
        expect(values(t), [true, false, false], reason: 'after tapping $k');
      }
      expect(w.groups.calls.where((c) => c.startsWith('settings')), isEmpty);
      expect(byKey('delete-group'), findsNothing, reason: 'members only');
    });

    for (final can in [true, false]) {
      testWidgets('a member gets the picture edit badge only when members '
          'may change the picture ($can)', (t) async {
        final w = clubWith(
          admin: false,
          settings: GroupSettings(membersCanSetAvatar: can),
        );
        await clubPage(t, w);
        expect(byKey('group-avatar-edit'), can ? findsOneWidget : findsNothing);
      });
    }

    testWidgets('an admin always gets the picture edit badge', (t) async {
      final w = clubWith(admin: true);
      await clubPage(t, w);
      expect(byKey('group-avatar-edit'), findsOneWidget);
    });

    for (final (i, k) in keys.indexed) {
      testWidgets('an admin flips $k in the same frame and the server is '
          'asked for that one switch only', (t) async {
        final w = clubWith(admin: true, settings: odd);
        await clubPage(t, w);
        await reveal(t, byKey(k));
        await t.ensureVisible(byKey(k));
        await t.pump();
        final before = values(t);
        await t.tap(byKey(k));
        await t.pump();
        final after = [...before]..[i] = !before[i];
        expect(values(t), after, reason: 'not flipped in the tap frame');
        final sent = [for (var j = 0; j < 3; j++) j == i ? '${after[i]}' : '-'];
        expect(w.groups.calls.where((c) => c.startsWith('settings')), [
          'settings:g1:${sent.join(':')}',
        ]);
        await settle(t);
        expect(values(t), after, reason: 'did not stay after the answer');
      });
    }

    testWidgets('a refused flip goes back and says so', (t) async {
      final w = clubWith(admin: true, settings: odd);
      w.groups.setResult = const Err(DeniedFailure());
      await clubPage(t, w);
      await reveal(t, byKey('setting-addsw'));
      await t.ensureVisible(byKey('setting-addsw'));
      await t.pump();
      await t.tap(byKey('setting-addsw'));
      await t.pump();
      expect(values(t), [true, true, false], reason: 'not optimistic');
      await settle(t);
      expect(values(t), [true, false, false], reason: 'not rolled back');
      expect(notice, findsOneWidget, reason: 'the refusal is not said');
      await drainNotice(t);
    });

    testWidgets('delete for everyone: the card names the group; cancel '
        'deletes nothing', (t) async {
      final w = clubWith(admin: true);
      await clubPage(t, w);
      await tapKey(t, 'delete-group');
      expect(byKey('delete-card'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing, reason: 'a dialog');
      expect(textOf(byKey('delete-card')), contains('Club'));
      await tapKey(t, 'delete-cancel');
      expect(byKey('delete-card'), findsNothing);
      expect(find.byType(GroupScreen), findsOneWidget);
      expect(w.groups.calls.where((c) => c.startsWith('delete')), isEmpty);
    });

    testWidgets('delete for everyone: confirm deletes through the real '
        'controller, says "Group deleted", and the group leaves the page '
        'and the list', (t) async {
      final w = clubWith(admin: true);
      await clubPage(t, w);
      await tapKey(t, 'delete-group');
      await t.tap(byKey('delete-confirm'));
      await settle(t);
      expect(w.groups.calls.where((c) => c.startsWith('delete')), [
        'delete:g1',
      ]);
      expect(find.byType(GroupScreen), findsNothing, reason: 'not popped');
      expect(find.byType(MessageScreen), findsNothing, reason: 'chat open');
      expect(t.widgetList<SisNotice>(notice).map((n) => n.message), [
        'Group deleted',
      ]);
      expect(byKey('conversation-g1'), findsNothing, reason: 'still listed');
      await drainNotice(t);
    });

    testWidgets('a refused delete keeps the group and says so', (t) async {
      final w = clubWith(admin: true);
      w.groups.deleteResult = const Err(DeniedFailure());
      await clubPage(t, w);
      await tapKey(t, 'delete-group');
      await t.tap(byKey('delete-confirm'));
      await settle(t);
      expect(w.groups.calls.where((c) => c.startsWith('delete')), [
        'delete:g1',
      ]);
      expect(find.byType(GroupScreen), findsOneWidget, reason: 'popped');
      expect(
        t.widgetList<SisNotice>(notice).map((n) => n.message),
        isNot(contains('Group deleted')),
      );
      expect(notice, findsOneWidget, reason: 'the refusal is not said');
      await drainNotice(t);
    });
  });

  group('rows', () {
    testWidgets('mute, add members and contact are settings rows; Message '
        'spans the page', (t) async {
      final w = World(
        self: 'u1',
        extra: [
          contactsRepositoryProvider.overrideWithValue(
            ContactsFake(directory: [me, bob, cem], reachable: ['ub']),
          ),
        ],
      );
      w.chat.groupRosters['g1'] = [
        const GroupMember(member: me, isAdmin: true),
        const GroupMember(member: bob, isAdmin: false, colorSlot: 1),
        const GroupMember(member: cem, isAdmin: false, colorSlot: 2),
      ];
      await clubPage(t, w);
      expect(t.widget(byKey('mute-tile')), isA<SisSettingsRow>());
      await reveal(t, byKey('add-members'));
      expect(t.widget(byKey('add-members')), isA<SisSettingsRow>());
      for (final k in [
        'group-member-ub',
        'toggle-admin-ub',
        'remove-member-ub',
      ]) {
        await reveal(t, byKey(k));
        expect(byKey(k), findsOneWidget, reason: k);
      }
      await tapKey(t, 'group-member-ub');
      expect(find.byType(PersonScreen), findsOneWidget);
      await reveal(t, byKey('person-contact-toggle'));
      expect(t.widget(byKey('person-contact-toggle')), isA<SisSettingsRow>());
      await reveal(t, byKey('person-message'));
      final page = t.getSize(find.byType(PersonScreen)).width;
      expect(
        t.getSize(byKey('person-message')).width,
        greaterThan(page * 0.8),
        reason: 'Message is not full width',
      );
    });
  });

  group('360 wide', () {
    testWidgets('the group page, every part of it, lays out without '
        'overflow', (t) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final w = World(self: 'u1');
      w.chat.groupRosters['g1'] = [
        const GroupMember(member: me, isAdmin: true),
        const GroupMember(member: bob, isAdmin: false, colorSlot: 1),
        const GroupMember(member: cem, isAdmin: false, colorSlot: 2),
      ];
      await clubPage(t, w);
      expect(t.getSize(find.byType(GroupScreen)).width, 360);
      for (final k in [
        'setting-pickswitch',
        'setting-addsw',
        'setting-histsw',
        'delete-group',
        'remove-member-u3',
        'leave-group',
        'mute-tile',
      ]) {
        await reveal(t, byKey(k));
        expect(byKey(k), findsOneWidget, reason: k);
      }
      await openCardAt(t);
      await tapKey(t, 'leave-cancel');
      for (final tab in ['tab-media', 'tab-links']) {
        await tapKey(t, tab);
      }
      expect(t.takeException(), isNull);
    });
  });

  // Slice 12: the data layer returns '' for a member whose profile name is
  // unknown (as the contract says SupabaseChatRepository does). Every place
  // that names them must show the localised "Member", never a blank and
  // never the domain's own wording.
  group('an unknown name', () {
    const nameless = Member(userId: 'u9', displayName: '');
    const withNameless = Conversation(
      id: 'c9',
      other: nameless,
      lastMessage: 'who?',
    );

    World unknown() => World()
      ..chat.conversationsResult = const Ok([withBob, club, withNameless])
      ..chat.roster['c9'] = [me, nameless]
      ..chat.roster['g1'] = [me, bob, nameless];

    testWidgets('the chat list row says "Member"', (t) async {
      await pumpApp(t, unknown());
      expect(textOf(byKey('conversation-c9')), contains(l10nEn.commonMember));
    });

    testWidgets('the open 1:1 header says "Member"', (t) async {
      await pumpApp(t, unknown());
      await openChat(t, 'c9');
      expect(
        textOf(byKey('conversation-title')),
        contains(l10nEn.commonMember),
      );
    });

    testWidgets('the group roster row says "Member"', (t) async {
      await clubPage(t, unknown());
      await tapKey(t, 'tab-members');
      await reveal(t, byKey('group-member-u9'));
      expect(textOf(byKey('group-member-u9')), contains(l10nEn.commonMember));
    });
  });
}

Future<void> openCardAt(WidgetTester t) async {
  await tapKey(t, 'leave-group');
  expect(byKey('leave-card'), findsOneWidget);
}

/// The production controller, but [leave] answers [unsent] and records the
/// call: the screen's notice is the subject, not the send queue.
class _LeaveSpy extends GroupController {
  _LeaveSpy(super.ref, this.unsent);
  final bool unsent;
  final left = <String>[];

  @override
  Future<Result<bool>> leave(String conversationId) async {
    left.add(conversationId);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return Ok(unsent);
  }
}

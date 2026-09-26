// The chat header as one pressable area, written from the contract: the
// whole title slot of MessageScreen's AppBar -- avatar, name, status and the
// empty space right of a short name -- opens the chat's profile. Reached the
// way a member reaches it: the whole app as main.dart mounts it, a chat
// tapped in the list. Fakes stand only at the repository boundaries. Run
// under TZ=JST-9 like every unit test.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/initials.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/person_avatar.dart';
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

const longName =
    'Bartholomew Maximilian Alexander Featherstonehaugh-Worthington '
    'the Third of Somewhere Very Far Away Indeed';
const lon = Member(userId: 'ul', displayName: longName, tag: 'long');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');
const club = Conversation(id: 'g1', title: 'Club', lastMessage: 'yo');
const withLon = Conversation(id: 'c9', other: lon, lastMessage: 'hey');

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

class World {
  World() {
    chat
      ..conversationsResult = const Ok([withBob, club, withLon])
      ..membersResult = const Ok([bob, cem, lon])
      ..roster['c1'] = [me, bob]
      ..roster['g1'] = [me, bob, cem]
      ..roster['c9'] = [me, lon];
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2));
  final presence = PresenceFake();
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

/// The open chat's AppBar.
Finder get appBar => find.descendant(
  of: find.byType(MessageScreen),
  matching: find.byType(AppBar),
);

/// The avatar in the header.
Finder get headerAvatar =>
    find.descendant(of: appBar, matching: find.byType(PersonAvatar));

/// The header's name text (the one-line title).
Finder headerName(String name) =>
    find.descendant(of: appBar, matching: find.text(name));

Future<void> tapAt(WidgetTester t, Offset at) async {
  await t.tapAt(at);
  await settle(t);
}

bool get profileOpen =>
    find.byType(PersonScreen).evaluate().isNotEmpty ||
    find.byType(GroupScreen).evaluate().isNotEmpty;

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
    }
    if (c == null) return true;
    found = c;
    return false;
  });
  expect(found, isNotNull, reason: 'no painted avatar behind "$initials"');
  return found!;
}

/// The point in the empty space far right of a short name: on the name's
/// line, 24 px in from the AppBar's right edge.
Offset farRight(WidgetTester t, String name) {
  final bar = t.getRect(appBar);
  final text = t.getRect(headerName(name));
  final at = Offset(bar.right - 24, text.center.dy);
  expect(
    at.dx,
    greaterThan(text.right + 100),
    reason: 'the name is not short enough to leave empty space',
  );
  return at;
}

void main() {
  setUpAll(() => HttpOverrides.global = ImageServer());

  group('the whole title slot is one pressable area', () {
    testWidgets('1:1: a tap in the empty space far right of a short name '
        'opens the person, without a Message button', (t) async {
      final w = World();
      await openChat(t, w, 'c1');
      await tapAt(t, farRight(t, 'Bob Stone'));
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(find.byType(GroupScreen), findsNothing);
      expect(byKey('person-message'), findsNothing);
    });

    testWidgets('group: a tap in the empty space far right of the name opens '
        'the group page', (t) async {
      final w = World();
      await openChat(t, w, 'g1');
      await tapAt(t, farRight(t, 'Club'));
      expect(find.byType(GroupScreen), findsOneWidget);
      expect(find.byType(PersonScreen), findsNothing);
    });

    testWidgets('a tap on the avatar opens the profile', (t) async {
      final w = World();
      await openChat(t, w, 'c1');
      expect(headerAvatar, findsOneWidget);
      await tapAt(t, t.getCenter(headerAvatar));
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(byKey('person-message'), findsNothing);
    });

    testWidgets('a tap on the avatar of a group opens the group page', (
      t,
    ) async {
      final w = World();
      await openChat(t, w, 'g1');
      await tapAt(t, t.getCenter(headerAvatar));
      expect(find.byType(GroupScreen), findsOneWidget);
    });

    testWidgets('a tap on the name opens the profile', (t) async {
      final w = World();
      await openChat(t, w, 'c1');
      await tapAt(t, t.getCenter(headerName('Bob Stone')));
      expect(find.byType(PersonScreen), findsOneWidget);
    });

    testWidgets('a tap on the status line, and right of it, opens the '
        'profile', (t) async {
      final w = World()..presence.setOthersOnline({'ub'});
      await openChat(t, w, 'c1');
      final status = byKey('conversation-status');
      expect(status, findsOneWidget);
      await tapAt(t, t.getCenter(status));
      expect(find.byType(PersonScreen), findsOneWidget);

      await t.pageBack();
      await settle(t);
      expect(find.byType(PersonScreen), findsNothing);
      final bar = t.getRect(appBar);
      await tapAt(t, Offset(bar.right - 24, t.getCenter(status).dy));
      expect(find.byType(PersonScreen), findsOneWidget);
    });

    testWidgets('conversation-title spans from the avatar to the right edge '
        'and is an ink-rippling area', (t) async {
      final w = World();
      await openChat(t, w, 'c1');
      final area = t.getRect(byKey('conversation-title'));
      final bar = t.getRect(appBar);
      final avatar = t.getRect(headerAvatar);
      final name = t.getRect(headerName('Bob Stone'));

      expect(area.left, lessThanOrEqualTo(avatar.left), reason: 'avatar');
      // The title slot ends at the AppBar's right padding (16 px).
      expect(area.right, greaterThanOrEqualTo(bar.right - 16));
      expect(area.right - name.right, greaterThan(100));

      // The ripple: an InkWell holding the avatar, as wide as the area.
      final inks = find.ancestor(
        of: headerAvatar,
        matching: find.byWidgetPredicate(
          (x) => x is InkWell && x.onTap != null,
        ),
      );
      expect(inks, findsWidgets, reason: 'no ink ripple around the header');
      expect(
        t.getRect(inks.first).right,
        greaterThanOrEqualTo(bar.right - 16),
        reason: 'the ripple does not reach the right edge',
      );
    });
  });

  group('the avatar', () {
    testWidgets('1:1: radius 18, the other person\'s initials, seeded by '
        'their user id -- the tint the chat list shows', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await settle(t);
      final initials = initialsOf('Bob Stone');
      final inList = tintOf(t, byKey('conversation-c1'), initials);

      await t.tap(byKey('conversation-c1'));
      await settle(t);
      final avatar = t.widget<PersonAvatar>(headerAvatar);
      expect(avatar.radius, 18);
      expect(avatar.seed, 'ub');
      expect(
        find.descendant(of: headerAvatar, matching: find.text(initials)),
        findsOneWidget,
      );
      expect(tintOf(t, appBar, initials), inList);
      // Left of the name.
      expect(
        t.getRect(headerAvatar).right,
        lessThanOrEqualTo(t.getRect(headerName('Bob Stone')).left),
      );
    });

    testWidgets('group: seeded by the conversation id -- the tint the chat '
        'list shows', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await settle(t);
      final initials = initialsOf('Club');
      final inList = tintOf(t, byKey('conversation-g1'), initials);

      await t.tap(byKey('conversation-g1'));
      await settle(t);
      final avatar = t.widget<PersonAvatar>(headerAvatar);
      expect(avatar.radius, 18);
      expect(avatar.seed, 'g1');
      expect(tintOf(t, appBar, initials), inList);
    });
  });

  group('name and status', () {
    testWidgets('a long name stays on one line, ellipsised, with no '
        'overflow, and the status sits under it', (t) async {
      final w = World()..presence.setOthersOnline({'ul'});
      await openChat(t, w, 'c9');
      expect(t.takeException(), isNull);

      final name = headerName(longName);
      expect(name, findsOneWidget);
      final paragraph = t.renderObject<RenderParagraph>(
        find.descendant(of: name, matching: find.byType(RichText)),
      );
      expect(paragraph.maxLines, 1);
      expect(paragraph.overflow, TextOverflow.ellipsis);
      expect(
        paragraph.didExceedMaxLines,
        isTrue,
        reason: 'the name is not long enough to test the ellipsis',
      );
      final nameRect = t.getRect(name);
      final bar = t.getRect(appBar);
      expect(nameRect.right, lessThanOrEqualTo(bar.right));
      // The same text laid out unwrapped is exactly one line tall.
      final oneLine = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout();
      expect(
        paragraph.size.height,
        lessThanOrEqualTo(oneLine.height + 0.5),
        reason: 'more than one line',
      );
      oneLine.dispose();

      final status = byKey('conversation-status');
      expect(status, findsOneWidget);
      expect(
        find.descendant(
          of: status,
          matching: find.text('online'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(t.getRect(status).top, greaterThanOrEqualTo(nameRect.bottom - 1));
      expect(
        find.descendant(of: appBar, matching: status),
        findsOneWidget,
        reason: 'status left the header',
      );
    });

    testWidgets('the status is under the name for a short name too', (t) async {
      final w = World()..presence.setOthersOnline({'ub'});
      await openChat(t, w, 'c1');
      final name = t.getRect(headerName('Bob Stone'));
      final status = byKey('conversation-status');
      expect(status, findsOneWidget);
      expect(t.getRect(status).top, greaterThanOrEqualTo(name.bottom - 1));
    });
  });

  for (final (kind, screen) in [
    ('a group', const MessageScreen(title: 'Club', group: true)),
    ('a 1:1', const MessageScreen(title: 'Bob', otherUserId: 'ub')),
  ]) {
    testWidgets('$kind with no conversation open: a tap on the header opens '
        'nothing', (t) async {
      final container = await settled(
        ProviderContainer.test(
          overrides: [
            chatRepositoryProvider.overrideWithValue(ChatFake()),
            presenceRepositoryProvider.overrideWithValue(PresenceFake()),
            attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
            sessionControllerProvider.overrideWith(_SignedIn.new),
          ],
        ),
      );
      expect(container.read(openConversationProvider), isNull);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: screen),
        ),
      );
      await t.pumpAndSettle();
      final title = byKey('conversation-title');
      expect(title, findsOneWidget);
      await t.tap(title);
      await t.pumpAndSettle();
      await t.tapAt(
        Offset(t.getRect(appBar).right - 24, t.getCenter(title).dy),
      );
      await t.pumpAndSettle();
      expect(profileOpen, isFalse);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

// Last seen on screen, written from the contract: the 1:1 header's status
// line, the settings switch, and HomeScreen reporting the member seen.
//
// The presence fake answers like last_seen_of and touch_last_seen: it reads
// the caller's sharing from the same profile row the settings screen saves,
// so a report made before that save lands is ignored exactly as the server
// ignores it. Run under TZ=JST-9 like every unit test.
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
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/domain/last_seen.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/sis_ui.dart';
import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');
const dee = Member(userId: 'u4', displayName: 'Dee');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');
const club = Conversation(id: 'g1', title: 'Club');

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

OwnProfile profile({bool lastSeen = true}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  shareLastSeen: lastSeen,
);

/// Long enough ago to be a date, so the label does not depend on the clock.
final longAgo = DateTime(2020, 1, 2, 3, 4);
const longAgoLabel = 'last seen 02.01.20';

class World {
  World({bool shareLastSeen = true})
    : profileFake = ProfileFake(profile: profile(lastSeen: shareLastSeen)) {
    presence = PresenceFake(owner: profileFake);
  }

  final ProfileFake profileFake;
  late final PresenceFake presence;
  final chat = ChatFake()
    ..conversationsResult = const Ok([withBob, club])
    ..membersResult = const Ok([me, bob, cem, dee]);

  /// The app as main.dart mounts it, fakes only at the repository boundary.
  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(presence),
      profileRepositoryProvider.overrideWithValue(profileFake),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

Future<void> pumpApp(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await t.pumpAndSettle();
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Future<void> settle(WidgetTester t) async {
  await t.pump(Duration.zero);
  await t.pumpAndSettle();
}

/// The header status line's text, or null when there is none.
String? status(WidgetTester t) {
  final f = find.byKey(const ValueKey('conversation-status'));
  if (f.evaluate().isEmpty) return null;
  final text = find
      .descendant(of: f, matching: find.byType(Text), matchRoot: true)
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .join()
      .trim();
  return text.isEmpty ? null : text;
}

Matcher oneTypist(String name) => anyOf('typing…', '$name is typing…');

Future<void> open(WidgetTester t, String id) async {
  await t.tap(find.byKey(ValueKey('conversation-$id')));
  await t.pumpAndSettle();
  expect(find.byType(MessageScreen), findsOneWidget);
}

void main() {
  group('1:1 header', () {
    testWidgets('an offline member with a known time shows last seen', (
      t,
    ) async {
      final w = World()..presence.lastSeen['u2'] = longAgo;
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), longAgoLabel);
    });

    testWidgets('the label is lastSeenLabel of that time and now', (t) async {
      final at = DateTime.now().subtract(const Duration(minutes: 10));
      final w = World()..presence.lastSeen['u2'] = at;
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), lastSeenLabel(at, DateTime.now()));
      expect(status(t), 'last seen 10 min ago');
    });

    testWidgets('online beats last seen', (t) async {
      final w = World()
        ..presence.lastSeen['u2'] = longAgo
        ..presence.setOthersOnline({'u2'});
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), 'online');
    });

    testWidgets('typing beats online, and online beats last seen again when '
        'the typing lapses', (t) async {
      final w = World()
        ..presence.lastSeen['u2'] = longAgo
        ..presence.setOthersOnline({'u2'});
      await pumpApp(t, w);
      await open(t, 'c1');
      w.presence.typingIn('c1')!.type('u2');
      await settle(t);
      expect(status(t), oneTypist('Bob'));

      await t.pump(typingLinger + const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      expect(status(t), 'online');
    });

    testWidgets('typing beats last seen', (t) async {
      final w = World()..presence.lastSeen['u2'] = longAgo;
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), longAgoLabel);

      w.presence.typingIn('c1')!.type('u2');
      await settle(t);
      expect(status(t), oneTypist('Bob'));

      await t.pump(typingLinger + const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      expect(status(t), longAgoLabel);
    });

    testWidgets('going offline replaces online with the fresh last seen', (
      t,
    ) async {
      final w = World()..presence.setOthersOnline({'u2'});
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), 'online');

      // Bob's app reports him seen as it goes to the background.
      w.presence.lastSeen['u2'] = longAgo;
      w.presence.setOthersOnline({});
      await settle(t);
      expect(status(t), longAgoLabel);
    });

    testWidgets('nothing when offline and no time is known', (t) async {
      final w = World();
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), isNull);
    });

    testWidgets('a member who hides their own sees nobody\'s', (t) async {
      final w = World(shareLastSeen: false)..presence.lastSeen['u2'] = longAgo;
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), isNull);
    });

    testWidgets('a failed lookup shows nothing, and no error', (t) async {
      final w = World()
        ..presence.lastSeen['u2'] = longAgo
        ..presence.lastSeenResult = const Err(NetworkFailure('no network'));
      await pumpApp(t, w);
      await open(t, 'c1');
      expect(status(t), isNull);
      expect(find.textContaining('no network'), findsNothing);
    });
  });

  group('group header', () {
    testWidgets('a group never shows last seen, whoever has one', (t) async {
      final w = World();
      w.presence.lastSeen
        ..['u2'] = longAgo
        ..['u3'] = longAgo
        ..['u4'] = longAgo
        ..['g1'] = longAgo;
      await pumpApp(t, w);
      await open(t, 'g1');
      expect(status(t), isNull);
      expect(find.textContaining('last seen'), findsNothing);
    });
  });

  group('settings switch', () {
    Finder tile() => find.byKey(const ValueKey('share-last-seen'));

    bool switchOn(WidgetTester t) => switchedOn(t, tile());

    Future<void> openSettings(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-privacy')));
      await t.pumpAndSettle();
      await t.ensureVisible(tile());
      await t.pumpAndSettle();
    }

    Future<void> flip(WidgetTester t) async {
      await t.tap(tile());
      await t.pumpAndSettle();
    }

    testWidgets('titled and explained, showing what the profile holds', (
      t,
    ) async {
      await pumpApp(t, World(shareLastSeen: false));
      await openSettings(t);

      expect(
        find.descendant(of: tile(), matching: find.text('Show my last seen')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tile(),
          matching: find.text(
            'While this is off, you can\'t see anyone else\'s either.',
          ),
        ),
        findsOneWidget,
      );
      expect(switchOn(t), isFalse);
    });

    testWidgets('on by default', (t) async {
      await pumpApp(t, World());
      await openSettings(t);
      expect(switchOn(t), isTrue);
    });

    testWidgets('turning it off saves only that', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openSettings(t);

      await flip(t);

      final s = w.profileFake.saves.single;
      expect(s.shareLastSeen, isFalse);
      expect(
        (s.displayName, s.tag, s.sharePresence, s.shareTyping),
        (null, null, null, null),
      );
      expect(w.profileFake.profile.shareLastSeen, isFalse);
      expect(switchOn(t), isFalse);
    });

    testWidgets('turning it on saves it, then reports the member seen once '
        'the save has landed', (t) async {
      final w = World(shareLastSeen: false);
      w.profileFake.holdSave();
      await pumpApp(t, w);
      await openSettings(t);
      expect(
        w.presence.lastSeen['u1'],
        isNull,
        reason: 'not sharing: no report can have been recorded yet',
      );
      final touchesBefore = w.presence.touches;

      await t.tap(tile());
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      w.profileFake.releaseSave();
      await t.pumpAndSettle();

      expect(w.profileFake.saves.single.shareLastSeen, isTrue);
      expect(switchOn(t), isTrue);
      expect(w.presence.touches, greaterThan(touchesBefore));
      expect(
        w.presence.lastSeen['u1'],
        isNotNull,
        reason:
            'the report went out before the save landed, so the server '
            'ignored it: the member stays unseen until the next resume',
      );
    });

    testWidgets('a refused change keeps the stored value and says why', (
      t,
    ) async {
      final w = World(shareLastSeen: false);
      w.profileFake.saveResult = const Err(
        NetworkFailure('the network is unreachable'),
      );
      await pumpApp(t, w);
      await openSettings(t);

      await flip(t);

      expect(w.profileFake.saves, hasLength(1));
      expect(switchOn(t), isFalse);
      expect(find.textContaining('the network is unreachable'), findsWidgets);
      expect(w.presence.lastSeen['u1'], isNull);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });
  });

  group('HomeScreen reports the member seen', () {
    testWidgets('once after the first frame, however often home rebuilds', (
      t,
    ) async {
      final w = World();
      await pumpApp(t, w);
      expect(w.presence.touches, 1);
      expect(w.presence.lastSeen['u1'], isNotNull);

      // Rebuild home a few ways: a new list, a settings round trip.
      w.chat.deliver(
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'hey',
          createdAt: DateTime.utc(2026, 9, 23, 12),
        ),
      );
      await settle(t);
      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();

      expect(w.presence.touches, 1);
    });

    testWidgets('when the app is hidden and when it resumes', (t) async {
      final w = World();
      await pumpApp(t, w);
      expect(w.presence.touches, 1);

      // To the background: resumed -> inactive -> hidden -> paused.
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      expect(w.presence.touches, 1, reason: 'inactive is not hidden');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await settle(t);
      expect(w.presence.touches, 2, reason: 'hiding the app reported nothing');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settle(t);
      expect(w.presence.touches, 2);

      // And back: paused -> hidden -> inactive -> resumed.
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(t);
      expect(w.presence.touches, 3, reason: 'resuming reported nothing');
    });

    testWidgets('a refused report leaves home working', (t) async {
      final w = World()
        ..presence.touchResult = const Err(NetworkFailure('no network'));
      await pumpApp(t, w);
      expect(w.presence.touches, 1);
      expect(find.textContaining('no network'), findsNothing);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await settle(t);
      expect(find.text('New chat'), findsOneWidget);
    });
  });
}

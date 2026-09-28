// A person's page shows their picture (owner bug: "the user profile picture
// is not visible on the user profile"). Written from the contract:
//
//  - PersonScreen's picture: the caller's fallbackAvatarPath first, else the
//    person's entry in yourPeopleProvider; the caller's wins when both exist and
//    differ. Neither -> initials. A picture that cannot be downloaded ->
//    initials. Never blank, never a spinner.
//  - The two callers that know a picture pass it: the 1:1 header
//    (conversation-title, from the conversation list) and a group's Members
//    row (group-member-<id>, from the conversation's member read).
//
// The whole app as main.dart mounts it (avatar_widgets_test's overrides),
// fakes only at the repository boundary; members() is made slow, failing,
// stale and outdated while the caller knows the current picture. Run under
// TZ=JST-9 like every unit test.
import 'dart:async';
import 'dart:typed_data';

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
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../profile/avatar_widgets_test.dart'
    show expectInitials, expectPicture, green, red, settle, tapKey;

/// Bob's current picture, which the caller knows, and one he had before.
const bobPath = 'profile/ub/bob-now.jpg';
const oldPath = 'profile/ub/bob-old.jpg';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');
Member bobWith(String? path) => Member(
  userId: 'ub',
  displayName: 'Bob Stone',
  tag: 'bobby',
  avatarPath: path,
);

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

/// What members() answers while the caller knows [bobPath].
enum People { slow, failing, stale, outdated }

/// ChatFake whose members() -- and only members(), not the conversation's
/// own member read -- can be held open, as a slow member-list query is.
class PeopleFake extends ChatFake {
  PeopleFake() : super(latency: const Duration(milliseconds: 2), self: 'u1');

  Completer<void>? _gate;
  void holdMembers() => _gate = Completer<void>();
  void releaseMembers() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<Result<List<Member>>> members() async {
    final gate = _gate;
    if (gate != null) await gate.future;
    return super.members();
  }
}

class World {
  /// [caller] is the picture the conversation list and the group's member
  /// read know for Bob; [people] is what members() does.
  World({String? caller = bobPath, People? people}) {
    final known = bobWith(caller);
    chat
      ..avatarBucket = bucket
      ..conversationsResult = Ok([
        Conversation(id: 'c1', other: known, lastMessage: 'hi'),
        const Conversation(id: 'g1', title: 'Club', lastMessage: 'yo'),
      ])
      ..membersResult = switch (people) {
        People.failing => const Err(NetworkFailure('No connection')),
        People.stale => Ok([bobWith(null), cem]),
        People.outdated => Ok([bobWith(oldPath), cem]),
        People.slow || null => Ok([known, cem]),
      }
      ..roster['c1'] = [me, known]
      ..roster['g1'] = [me, known, cem]
      ..history['c1'] = [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'ub',
          body: 'hi',
          createdAt: DateTime.utc(2026, 9, 20, 10),
        ),
      ]
      ..history['g1'] = [
        Message(
          id: 'm2',
          conversationId: 'g1',
          senderId: 'u3',
          body: 'yo',
          createdAt: DateTime.utc(2026, 9, 20, 11),
        ),
      ];
    if (people == People.slow) chat.holdMembers();
    bucket[bobPath] = green;
    bucket[oldPath] = red;
  }

  final bucket = <String, Uint8List>{};
  final chat = PeopleFake();

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
          bucket: bucket,
          profile: const OwnProfile(
            userId: 'u1',
            displayName: 'Maya Kaya',
            tag: 'maya',
            onboardingDone: true,
          ),
        ),
      ),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

Future<void> home(WidgetTester t, World w) async {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  addTearDown(w.chat.releaseMembers);
  await t.pumpWidget(w.app());
  await settle(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

final person = find.byType(PersonScreen);

/// (a) the 1:1 header's title.
Future<void> fromChatHeader(WidgetTester t) async {
  await tapKey(t, 'conversation-c1');
  await tapKey(t, 'conversation-title');
  expect(person, findsOneWidget, reason: 'the person page did not open');
}

/// (b) a group's page -> Members -> Bob's row.
Future<void> fromGroupMembers(WidgetTester t) async {
  await tapKey(t, 'conversation-g1');
  await tapKey(t, 'conversation-title');
  expect(find.byType(GroupScreen), findsOneWidget);
  await tapKey(t, 'tab-members');
  await tapKey(t, 'group-member-ub');
  expect(person, findsOneWidget, reason: 'the person page did not open');
}

/// A caller that knows nothing but the id (and maybe a name).
Future<void> openBare(WidgetTester t, {String? name}) async {
  unawaited(
    Navigator.of(t.element(find.text('New chat'))).push(
      MaterialPageRoute<void>(
        builder: (_) => PersonScreen(userId: 'ub', fallbackName: name),
      ),
    ),
  );
  await settle(t);
  expect(person, findsOneWidget);
}

void main() {
  group('the caller\'s picture shows although the member list', () {
    final entries = {
      '1:1 header': fromChatHeader,
      'group Members row': fromGroupMembers,
    };
    const says = {
      People.slow: 'has not answered yet',
      People.failing: 'failed to load',
      People.stale: 'has no picture for them (stale)',
      People.outdated: 'has their old picture',
    };
    for (final entry in entries.entries) {
      for (final people in People.values) {
        testWidgets('${says[people]} -- via the ${entry.key}', (t) async {
          final w = World(people: people);
          await home(t, w);
          await entry.value(t);
          expectPicture(person, green, '${entry.key}, members ${people.name}');
        });
      }
    }
  });

  group('a caller with no picture to pass', () {
    testWidgets('the member list\'s picture shows', (t) async {
      final w = World();
      await home(t, w);
      await openBare(t);
      expectPicture(person, green, 'from the member list');
    });

    testWidgets('neither has one: initials, not blank', (t) async {
      final w = World(caller: null, people: People.stale);
      await home(t, w);
      await openBare(t);
      expectInitials(person, 'Bob Stone', 'no picture anywhere');
      await t.pageBack();
      await settle(t);
      await fromChatHeader(t);
      expectInitials(person, 'Bob Stone', '1:1 header, no picture anywhere');
    });

    testWidgets('the member list still loading: initials, never a spinner', (
      t,
    ) async {
      final w = World(people: People.slow);
      await home(t, w);
      await openBare(t, name: 'Bob Stone');
      expectInitials(person, 'Bob Stone', 'member list in flight');
    });

    testWidgets('the member list failed: initials', (t) async {
      final w = World(people: People.failing);
      await home(t, w);
      await openBare(t, name: 'Bob Stone');
      expectInitials(person, 'Bob Stone', 'member list failed');
    });
  });

  group('a picture that cannot be downloaded shows initials', () {
    for (final entry in {
      '1:1 header': fromChatHeader,
      'group Members row': fromGroupMembers,
    }.entries) {
      testWidgets('the caller\'s, via the ${entry.key}', (t) async {
        final w = World(people: People.stale);
        w.chat.avatarFailures[bobPath] = const NetworkFailure('No connection');
        await home(t, w);
        await entry.value(t);
        expect(w.chat.avatarRequests, contains(bobPath), reason: 'not tried');
        expectInitials(person, 'Bob Stone', entry.key);
      });
    }

    testWidgets('the member list\'s', (t) async {
      final w = World();
      w.chat.avatarFailures[bobPath] = const DeniedFailure();
      await home(t, w);
      await openBare(t);
      expect(w.chat.avatarRequests, contains(bobPath), reason: 'not tried');
      expectInitials(person, 'Bob Stone', 'member list picture refused');
    });
  });
}

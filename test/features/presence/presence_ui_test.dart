// Widget tests for online status and typing, written from the contract: the
// green dot on a 1:1 tile, the header subtitle of an open conversation, and
// the composer announcing typing — never how the widgets are built.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');
const dee = Member(userId: 'u4', displayName: 'Dee');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');

/// A group as the real repository returns one: a title and no counterpart.
const club = Conversation(id: 'g1', title: 'Club');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

OwnProfile profile({bool typing = true}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  shareTyping: typing,
);

class World {
  World({bool shareTyping = true})
    : profileFake = ProfileFake(profile: profile(typing: shareTyping));

  final chat = ChatFake()
    ..conversationsResult = const Ok([withBob, club])
    ..membersResult = const Ok([me, bob, cem, dee]);
  final presence = PresenceFake();
  final ProfileFake profileFake;

  Future<ProviderContainer> container() async {
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(presence),
        profileRepositoryProvider.overrideWithValue(profileFake),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    );
    await settled(c);
    c.listen(ownProfileProvider, (_, _) {});
    return c;
  }
}

Future<ProviderContainer> pump(
  WidgetTester t,
  World w, {
  Widget home = const ConversationList(),
  String? open,
}) async {
  final c = await w.container();
  if (open != null) c.read(openConversationProvider.notifier).open(open);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: home),
    ),
  );
  await t.pumpAndSettle();
  return c;
}

Future<void> settle(WidgetTester t) async {
  await t.pump(Duration.zero);
  await t.pumpAndSettle();
}

/// The header subtitle's text, or null when there is none.
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

/// One typist: the contract allows the bare or the named form.
Matcher oneTypist(String name) => anyOf('typing…', '$name is typing…');

Finder dot(String conversationId) =>
    find.byKey(ValueKey('online-$conversationId'));

Message from(String userId, {String conversation = 'c1'}) => Message(
  id: 'm-$userId-${DateTime.now().microsecondsSinceEpoch}',
  conversationId: conversation,
  senderId: userId,
  body: 'hello',
  createdAt: DateTime.utc(2026, 9, 23, 12),
);

void main() {
  group('conversation list', () {
    testWidgets('a 1:1 whose other member is online shows a dot, live', (
      t,
    ) async {
      final w = World();
      await pump(t, w);
      expect(dot('c1'), findsNothing, reason: 'nobody is online yet');

      w.presence.setOthersOnline({'u2'});
      await settle(t);
      expect(dot('c1'), findsOneWidget);

      w.presence.setOthersOnline({});
      await settle(t);
      expect(dot('c1'), findsNothing, reason: 'Bob left and the dot stayed');
    });

    testWidgets('someone else online does not light the tile', (t) async {
      final w = World()..presence.setOthersOnline({'u3', 'u4'});
      await pump(t, w);
      expect(dot('c1'), findsNothing);
    });

    testWidgets('a group never shows a dot, whoever is online', (t) async {
      final w = World()..presence.setOthersOnline({'u2', 'u3', 'u4'});
      await pump(t, w);
      expect(dot('c1'), findsOneWidget, reason: 'the fixture is not online');
      expect(dot('g1'), findsNothing);
    });

    testWidgets('presence that cannot be joined leaves the list working', (
      t,
    ) async {
      final w = World()
        ..presence.onlineRefusal = const NetworkFailure('no network');
      await pump(t, w);
      expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
      expect(dot('c1'), findsNothing);
      expect(find.textContaining('no network'), findsNothing);
    });
  });

  group('message screen header', () {
    // The way production reaches the screen: from the list, which it sits on.
    Future<ProviderContainer> openWith(
      WidgetTester t,
      World w, {
      String id = 'c1',
    }) async {
      final c = await pump(t, w);
      await t.tap(find.byKey(ValueKey('conversation-$id')));
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
      return c;
    }

    testWidgets('a 1:1 with the other member online says online', (t) async {
      final w = World()..presence.setOthersOnline({'u2'});
      await openWith(t, w);
      expect(status(t), 'online');
    });

    testWidgets('online follows the other member while the screen is open', (
      t,
    ) async {
      final w = World();
      await openWith(t, w);
      expect(status(t), isNull);

      w.presence.setOthersOnline({'u2'});
      await settle(t);
      expect(status(t), 'online');

      w.presence.setOthersOnline({});
      await settle(t);
      expect(status(t), isNull);
    });

    testWidgets('a 1:1 with the other member offline says nothing', (t) async {
      final w = World()..presence.setOthersOnline({'u3'});
      await openWith(t, w);
      expect(status(t), isNull);
    });

    testWidgets('a group never says online', (t) async {
      final w = World()..presence.setOthersOnline({'u2', 'u3'});
      await openWith(t, w, id: 'g1');
      expect(status(t), isNull);
    });

    testWidgets('a 1:1 typist shows typing, then back to online after the '
        'linger', (t) async {
      final w = World()..presence.setOthersOnline({'u2'});
      await openWith(t, w);
      w.presence.typingIn('c1')!.type('u2');
      await settle(t);
      expect(status(t), oneTypist('Bob'));

      await t.pump(typingLinger + const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      expect(status(t), 'online');
    });

    testWidgets('one typist in a group is named from the members list', (
      t,
    ) async {
      final w = World();
      await openWith(t, w, id: 'g1');
      w.presence.typingIn('g1')!.type('u3');
      await settle(t);
      expect(status(t), 'Cem is typing…');
      await t.pump(typingLinger * 2);
    });

    testWidgets('a typist missing from the members list is not named', (
      t,
    ) async {
      final w = World();
      await openWith(t, w, id: 'g1');
      w.presence.typingIn('g1')!.type('u9');
      await settle(t);
      expect(status(t), 'typing…');
      await t.pump(typingLinger * 2);
    });

    testWidgets('several typists in a group are counted', (t) async {
      final w = World();
      await openWith(t, w, id: 'g1');
      w.presence.typingIn('g1')!
        ..type('u3')
        ..type('u4');
      await settle(t);
      expect(status(t), '2 people are typing…');
      await t.pump(typingLinger * 2);
    });

    testWidgets('a message from the typist clears their typing at once', (
      t,
    ) async {
      final w = World()..presence.setOthersOnline({'u2'});
      await openWith(t, w);
      w.presence.typingIn('c1')!.type('u2');
      await settle(t);
      expect(status(t), oneTypist('Bob'));

      w.chat.deliver(from('u2'));
      await settle(t);
      expect(status(t), 'online', reason: 'typing… outlived the message');
      await t.pump(typingLinger * 2);
    });

    testWidgets('a message from someone else leaves a group typist alone', (
      t,
    ) async {
      final w = World();
      await openWith(t, w, id: 'g1');
      w.presence.typingIn('g1')!.type('u3');
      await settle(t);

      w.chat.deliver(from('u4', conversation: 'g1'));
      await settle(t);
      expect(status(t), 'Cem is typing…');
      await t.pump(typingLinger * 2);
    });
  });

  group('composer', () {
    Future<void> type(WidgetTester t, String text) async {
      await t.enterText(find.byKey(const ValueKey('composer-field')), text);
      await t.pump();
    }

    testWidgets('typing in the composer announces it, throttled', (t) async {
      final w = World();
      await pump(
        t,
        w,
        open: 'c1',
        home: const MessageScreen(title: 'Bob'),
      );
      final channel = w.presence.typingIn('c1')!;

      await type(t, 'h');
      await type(t, 'he');
      await type(t, 'hel');
      expect(channel.signals, 1);
    });

    testWidgets('with typing sharing off the composer announces nothing', (
      t,
    ) async {
      final w = World(shareTyping: false);
      await pump(
        t,
        w,
        open: 'c1',
        home: const MessageScreen(title: 'Bob'),
      );

      await type(t, 'hello');
      expect(w.presence.typingIn('c1')!.signals, 0);
    });

    testWidgets('leaving the conversation closes its typing channel', (
      t,
    ) async {
      final w = World();
      await pump(t, w);
      await t.tap(find.byKey(const ValueKey('conversation-c1')));
      await t.pumpAndSettle();
      final channel = w.presence.typingIn('c1');
      expect(channel, isNotNull, reason: 'opening joined no typing channel');

      await t.pageBack();
      await t.pumpAndSettle();
      expect(channel!.closed, isTrue);
    });
  });
}

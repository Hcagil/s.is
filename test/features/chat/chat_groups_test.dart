// Widget tests for the v0.3 presentation contract: the group composer and a
// conversation list that labels a group by its title. Written from the
// contract — what a member sees and what the repository is asked for — never
// from how the widgets are built. Renaming moved to the profile feature in
// v0.4 and is tested under test/features/profile/.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cleo = Member(userId: 'u3', displayName: 'Cleo');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'see you');
const trip = Conversation(
  id: 'g7',
  title: 'Weekend trip',
  lastMessage: 'bring boots',
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

ProviderContainer _scope(ChatFake chat) => ProviderContainer.test(
  overrides: [
    chatRepositoryProvider.overrideWithValue(chat),
    sessionControllerProvider.overrideWith(_SignedIn.new),
  ],
);

Future<ProviderContainer> pump(
  WidgetTester tester,
  ChatFake chat, {
  Widget home = const ConversationList(),
}) async {
  final container = _scope(chat);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Opens the group composer with members to pick from.
Future<ProviderContainer> openComposer(
  WidgetTester tester,
  ChatFake chat,
) async {
  chat.membersResult = const Ok([bob, cleo]);
  final container = await pump(tester, chat);
  await tester.tap(find.byKey(const ValueKey('new-group')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('group-title')),
    findsOneWidget,
    reason: 'the group composer did not open',
  );
  return container;
}

Future<void> tapCreate(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey('group-create')),
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
}

void expectNoRawException(WidgetTester tester) {
  final leaked = find.byWidgetPredicate((w) {
    final data = w is Text ? (w.data ?? '') : '';
    return data.contains('Instance of') ||
        data.contains('Failure(') ||
        data.contains('Exception');
  });
  expect(leaked, findsNothing, reason: 'a raw exception string reached the UI');
}

void main() {
  group('group composer', () {
    testWidgets('creates nothing until there is a title AND a member', (
      tester,
    ) async {
      final chat = ChatFake();
      await openComposer(tester, chat);

      // Nothing chosen at all.
      await tapCreate(tester);
      expect(chat.groups, isEmpty, reason: 'created a group out of nothing');

      // A title on its own is not a group.
      await tester.enterText(
        find.byKey(const ValueKey('group-title')),
        'Weekend trip',
      );
      await tester.pump();
      await tapCreate(tester);
      expect(chat.groups, isEmpty, reason: 'created a group with no members');

      // A member on their own is not a group either.
      await tester.enterText(find.byKey(const ValueKey('group-title')), '   ');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('group-member-u2')));
      await tester.pumpAndSettle();
      await tapCreate(tester);
      expect(chat.groups, isEmpty, reason: 'whitespace passed as a title');

      // Deselecting the only member takes the group back to nothing.
      await tester.enterText(
        find.byKey(const ValueKey('group-title')),
        'Weekend trip',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('group-member-u2')));
      await tester.pumpAndSettle();
      await tapCreate(tester);
      expect(
        chat.groups,
        isEmpty,
        reason: 'a deselected member still counted as a member',
      );

      expect(
        find.byKey(const ValueKey('group-title')),
        findsOneWidget,
        reason: 'the composer closed without creating anything',
      );
    });

    testWidgets('creates the group with exactly the members picked', (
      tester,
    ) async {
      final chat = ChatFake()..conversationsResult = const Ok([withBob]);
      final container = await openComposer(tester, chat);

      await tester.enterText(
        find.byKey(const ValueKey('group-title')),
        'Weekend trip',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('group-member-u2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-member-u3')));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(chat.groups, hasLength(1), reason: 'the RPC was not reached once');
      expect(chat.groups.single.title.trim(), 'Weekend trip');
      expect(
        chat.groups.single.memberIds,
        unorderedEquals(<String>['u2', 'u3']),
        reason: 'the group was created with the wrong people in it',
      );

      // The new group is opened, and the list behind it has been re-read.
      expect(container.read(openConversationProvider), isNotNull);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(
        chat.calls.where((c) => c == 'conversations').length,
        greaterThan(1),
        reason: 'the list never refreshed, so the group is missing from it',
      );
    });

    testWidgets('a refused group shows the reason and opens nothing', (
      tester,
    ) async {
      final chat = ChatFake()..groupResult = const Err(DeniedFailure());
      final container = await openComposer(tester, chat);

      await tester.enterText(
        find.byKey(const ValueKey('group-title')),
        'Weekend trip',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('group-member-u2')));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(find.textContaining('Not allowed'), findsAtLeastNWidgets(1));
      expect(find.byType(MessageScreen), findsNothing);
      expect(
        container.read(openConversationProvider),
        isNull,
        reason: 'a conversation that was never created was opened',
      );
      expectNoRawException(tester);
      // Let the SnackBar timer expire inside the test.
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });
  });

  group('conversation list', () {
    testWidgets('a group is labelled by its title, not by a person', (
      tester,
    ) async {
      final chat = ChatFake()..conversationsResult = const Ok([trip, withBob]);
      await pump(tester, chat);

      final tile = find.byKey(const ValueKey('conversation-g7'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text('Weekend trip')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tile, matching: find.text('Bob')),
        findsNothing,
        reason: 'a group was labelled with a member instead of its title',
      );
      expect(
        find.descendant(of: tile, matching: find.text('Conversation')),
        findsNothing,
        reason: 'the fallback label was used for a titled group',
      );
      // The 1:1 beside it still names the person.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('conversation-c1')),
          matching: find.text('Bob'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping a group opens it', (tester) async {
      final chat = ChatFake()..conversationsResult = const Ok([trip]);
      final container = await pump(tester, chat);

      await tester.tap(find.byKey(const ValueKey('conversation-g7')));
      await tester.pumpAndSettle();

      expect(container.read(openConversationProvider), 'g7');
      expect(find.byType(MessageScreen), findsOneWidget);
    });
  });

  // Display names are not unique; the tag is what tells two Bobs apart, so
  // both pickers must show it under the name.
  group('member pickers show the tag', () {
    const bobA = Member(userId: 'u2', displayName: 'Bob', tag: 'bob_a');
    const bobB = Member(userId: 'u3', displayName: 'Bob', tag: 'bob_b');
    const untagged = Member(userId: 'u4', displayName: 'Old client');

    Finder under(String key, String text) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.text(text),
    );

    testWidgets('new chat', (tester) async {
      final chat = ChatFake()..membersResult = const Ok([bobA, bobB, untagged]);
      await pump(tester, chat);
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();

      expect(under('member-u2', '@bob_a'), findsOneWidget);
      expect(under('member-u3', '@bob_b'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('member-u4')),
          matching: find.textContaining('@'),
        ),
        findsNothing,
        reason: 'a member without a tag was shown a made-up one',
      );
    });

    testWidgets('new group', (tester) async {
      final chat = ChatFake();
      await pump(tester, chat);
      chat.membersResult = const Ok([bobA, bobB, untagged]);
      await tester.tap(find.byKey(const ValueKey('new-group')));
      await tester.pumpAndSettle();

      expect(under('group-member-u2', '@bob_a'), findsOneWidget);
      expect(under('group-member-u3', '@bob_b'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('group-member-u4')),
          matching: find.textContaining('@'),
        ),
        findsNothing,
      );
    });
  });
}

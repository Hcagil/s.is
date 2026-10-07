// The poll bubble in a real MessageScreen, against PollFake (test/support).
// Written from the contract: results (bars, percents) stay hidden until I
// vote or the poll closes; a single-choice tap votes on the same frame; a
// multiple-choice poll votes with poll-vote; the long-press card offers
// retract-vote / stop-poll; View votes lists voters, never on anonymous polls.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/features/chat/domain/poll.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';
import '../../support/poll_fakes.dart';
import 'conversation_list_live_test.dart' show scope;

Finder k(String key) => find.byKey(ValueKey(key));

/// A poll message m1 from [from], 'Lunch?' with options a 'Pizza', b 'Soup'.
Message pollMessage({String from = 'u2', bool sending = false}) => Message(
  id: 'm1',
  conversationId: 'c1',
  senderId: from,
  body: 'Lunch?',
  createdAt: DateTime.now(),
  poll: true,
  sending: sending,
);

Poll lunch({
  bool multiple = false,
  bool anonymous = false,
  bool closed = false,
}) => Poll(
  messageId: 'm1',
  question: 'Lunch?',
  options: const [
    PollOption(id: 'a', text: 'Pizza', votes: 0),
    PollOption(id: 'b', text: 'Soup', votes: 0),
  ],
  multiple: multiple,
  anonymous: anonymous,
  closed: closed,
  voters: 0,
);

/// Opens chat c1 showing the poll; [fake] already seeded by the caller.
Future<void> show(
  WidgetTester t,
  PollFake fake, {
  String from = 'u2',
  bool sending = false,
  Locale? locale,
}) async {
  await openChat(
    t,
    messages: [pollMessage(from: from, sending: sending)],
    polls: fake,
    locale: locale,
  );
  await t.pumpAndSettle();
  expect(k('poll-m1'), findsOneWidget, reason: 'poll card not shown');
}

/// The bar fill fraction of option [id].
double bar(WidgetTester t, String id) => t
    .widget<FractionallySizedBox>(
      find
          .descendant(
            of: k('poll-bar-$id'),
            matching: find.byType(FractionallySizedBox),
          )
          .first,
    )
    .widthFactor!;

/// Long-presses the poll message: the action card opens.
Future<void> menu(WidgetTester t) async {
  await t.longPress(k('message-m1'));
  await t.pumpAndSettle();
  expect(k('message-menu'), findsOneWidget);
}

/// The chat list whose only chat c1 last showed [lastMessage].
Future<void> list(WidgetTester t, String lastMessage, {Locale? locale}) async {
  final chat = ChatFake()
    ..conversationsResult = Ok([
      Conversation(
        id: 'c1',
        other: bob,
        lastMessage: lastMessage,
        lastMessageAt: DateTime.now().toUtc(),
        lastSenderId: bob.userId,
      ),
    ]);
  final c = scope(chat);
  addTearDown(c.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const ConversationList(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// A 360 dp wide phone, set after the chat opened.
Future<void> narrow(WidgetTester t) async {
  t.view.physicalSize = const Size(1080, 2220);
  t.view.devicePixelRatio = 3;
  await t.pumpAndSettle();
}

void main() {
  testWidgets('single choice: one tap votes on the same frame, results show', (
    t,
  ) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        ballots: {
          'u3': {'b'},
        },
      );
    await show(t, fake);
    expect(k('poll-bar-a'), findsNothing, reason: 'results before voting');
    await t.tap(k('poll-option-a'));
    await t.pump();
    expect(k('poll-mine-a'), findsOneWidget);
    expect(find.text('50%'), findsNWidgets(2));
    expect(bar(t, 'a'), closeTo(0.5, 0.001));
    await t.pumpAndSettle();
    expect(fake.voteCalls.single.$1, 'm1');
    expect(fake.voteCalls.single.$2, {'a'});
  });

  testWidgets('pending poll ignores taps', (WidgetTester t) async {
    final fake = PollFake()..seed('c1', lunch(), creator: 'u2', ballots: {});
    await show(t, fake, from: 'u1', sending: true);
    await t.tap(k('poll-option-a'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(fake.voteCalls, isEmpty);
    expect(k('poll-mine-a'), findsNothing);
  });

  testWidgets('multiple choice votes with the Vote button', (
    WidgetTester t,
  ) async {
    final fake = PollFake()
      ..seed('c1', lunch(multiple: true), creator: 'u2', ballots: {});
    await show(t, fake);
    await t.tap(k('poll-option-a'));
    await t.tap(k('poll-option-b'));
    await t.pumpAndSettle();
    expect(fake.voteCalls, isEmpty);
    await t.tap(k('poll-vote-m1'));
    await t.pumpAndSettle();
    expect(fake.voteCalls.length, 1);
    expect(fake.voteCalls.single.$2, {'a', 'b'});
    expect(k('poll-mine-a'), findsOneWidget);
    expect(k('poll-mine-b'), findsOneWidget);
  });

  testWidgets('a closed poll shows final results without voting', (
    WidgetTester t,
  ) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(closed: true),
        creator: 'u2',
        ballots: {
          'u2': {'a'},
          'u3': {'a'},
        },
      );
    await show(t, fake);
    await t.pumpAndSettle();
    expect(k('poll-bar-a'), findsOneWidget);
    expect(bar(t, 'a'), closeTo(1.0, 0.001));
    expect(find.text('Final results'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('another member vote updates my results live', (
    WidgetTester t,
  ) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        creator: 'u2',
        ballots: {
          'u3': {'b'},
        },
      );
    await show(t, fake);
    await t.tap(k('poll-option-a'));
    await t.pumpAndSettle();
    fake.others('m1', 'u2', {'a'});
    await t.pumpAndSettle();
    expect(bar(t, 'a'), closeTo(2 / 3, 0.001));
    expect(bar(t, 'b'), closeTo(1 / 3, 0.001));
  });

  testWidgets('a vote refused as closed says the poll is closed', (
    WidgetTester t,
  ) async {
    final fake = PollFake()..seed('c1', lunch(), creator: 'u2', ballots: {});
    fake.onVote = (id, set) async => const Err(PollClosedFailure());
    await show(t, fake);
    await t.tap(k('poll-option-a'));
    await t.pumpAndSettle();
    expect(find.text('This poll is closed.'), findsOneWidget);
    expect(k('poll-mine-a'), findsNothing);
  });

  testWidgets('retract from the card clears my vote and hides results', (
    WidgetTester t,
  ) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        creator: 'u2',
        ballots: {
          'u1': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake, from: 'u1');
    expect(k('poll-mine-a'), findsOneWidget);
    await menu(t);
    await t.tap(k('menu-retract-vote'));
    await t.pumpAndSettle();
    expect(fake.voteCalls.single.$2, isEmpty);
    expect(k('poll-mine-a'), findsNothing);
    expect(k('poll-bar-a'), findsNothing);
  });

  testWidgets('a poll offers no edit, forward or copy', (WidgetTester t) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        creator: 'u2',
        ballots: {
          'u1': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake, from: 'u1');
    await menu(t);
    expect(k('menu-edit'), findsNothing);
    expect(k('menu-forward'), findsNothing);
    expect(k('menu-copy'), findsNothing);
  });

  testWidgets('the creator stops the poll after confirming', (
    WidgetTester t,
  ) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        creator: 'u1',
        ballots: {
          'u2': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake, from: 'u1');
    await menu(t);
    expect(k('menu-retract-vote'), findsNothing);
    await t.tap(k('menu-stop-poll'));
    await t.pumpAndSettle();
    expect(k('stop-poll-card'), findsOneWidget);
    await t.tap(k('stop-poll-cancel'));
    await t.pumpAndSettle();
    expect(fake.closeCalls, isEmpty);
    await menu(t);
    await t.tap(k('menu-stop-poll'));
    await t.pumpAndSettle();
    await t.tap(k('stop-poll-confirm'));
    await t.pumpAndSettle();
    expect(fake.closeCalls, equals(['m1']));
    expect(find.text('Final results'), findsOneWidget);
    expect(k('poll-bar-a'), findsOneWidget);
  });

  testWidgets('only the creator can stop', (WidgetTester t) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        creator: 'u2',
        ballots: {
          'u2': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake);
    await menu(t);
    expect(k('menu-stop-poll'), findsNothing);
  });

  testWidgets('view votes lists who voted for what', (WidgetTester t) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(closed: true),
        creator: 'u2',
        ballots: {
          'u2': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake);
    await t.tap(k('poll-view-votes-m1'));
    await t.pumpAndSettle();
    expect(k('poll-voters-card'), findsOneWidget);
    expect(k('poll-voter-a-u2'), findsOneWidget);
    expect(k('poll-voter-b-u3'), findsOneWidget);
  });

  testWidgets('an anonymous poll never offers view votes', (
    WidgetTester t,
  ) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(closed: true, anonymous: true),
        creator: 'u2',
        ballots: {
          'u2': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake);
    expect(k('poll-bar-a'), findsOneWidget);
    expect(k('poll-view-votes-m1'), findsNothing);
  });

  testWidgets('an option nobody chose shows a 0% bar', (WidgetTester t) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(),
        ballots: {
          'u3': {'a'},
        },
      );
    await show(t, fake);
    await t.tap(k('poll-option-a'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(bar(t, 'a'), closeTo(1.0, 0.001));
    expect(bar(t, 'b'), closeTo(0.0, 0.001));
    expect(find.text('0%'), findsOneWidget);
  });

  testWidgets('Turkish at 360 dp: a closed poll fits', (WidgetTester t) async {
    final fake = PollFake()
      ..seed(
        'c1',
        lunch(closed: true),
        ballots: {
          'u2': {'a'},
          'u3': {'b'},
        },
      );
    await show(t, fake, locale: const Locale('tr'));
    await narrow(t);
    expect(t.takeException(), isNull);
    expect(find.text('Kesin Sonuçlar'), findsOneWidget);
  });

  testWidgets('the chat list shows a poll in English', (WidgetTester t) async {
    await list(t, pollPreview('Lunch?'));
    expect(
      find.descendant(
        of: k('preview-c1'),
        matching: find.text('📊 Poll: Lunch?'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the chat list shows a poll in Turkish', (WidgetTester t) async {
    await list(t, pollPreview('Lunch?'), locale: const Locale('tr'));
    expect(
      find.descendant(
        of: k('preview-c1'),
        matching: find.text('📊 Anket: Lunch?'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
  });
}

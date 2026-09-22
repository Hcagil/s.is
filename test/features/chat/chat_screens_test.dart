// Widget tests for the chat presentation layer, written from the contract:
// what a member sees and what the repository is asked to do — never how the
// widgets are built.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/home/presentation/home_screen.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

const withBob = Conversation(
  id: 'c1',
  other: bob,
  lastMessage: 'see you',
  lastMessageAt: null,
);

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String conversation = 'c1',
  int minute = 0,
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 22, 12, minute),
);

/// A signed-in member, so the screens know whose messages are whose without
/// dragging the auth SDK into a widget test.
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
  String? open,
}) async {
  final container = _scope(chat);
  if (open != null) {
    container.read(openConversationProvider.notifier).open(open);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// What is currently typed in the composer.
String composerText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-field')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

/// Any visible text of real length — the difference between guidance and a
/// blank screen, without pinning the wording.
final guidance = find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').trim().length >= 15,
);

/// Raw exception and type names must never reach a member.
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
  group('conversation list', () {
    testWidgets('empty guides the member instead of showing nothing', (
      tester,
    ) async {
      await pump(tester, ChatFake());

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        guidance,
        findsAtLeastNWidgets(1),
        reason: 'an empty list must explain what to do next',
      );
      expect(find.text('New chat'), findsOneWidget);
    });

    testWidgets('a failed load shows the reason and retries', (tester) async {
      final chat = ChatFake()
        ..conversationsResult = const Err(
          NetworkFailure('the network is unreachable'),
        );
      await pump(tester, chat);

      expect(find.textContaining('the network is unreachable'), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'a failure must not spin forever',
      );
      expectNoRawException(tester);

      // The retry affordance must actually ask the repository again.
      chat.conversationsResult = const Ok([withBob]);
      final retry = find.byWidgetPredicate((w) => w is ButtonStyleButton);
      expect(retry, findsAtLeastNWidgets(1), reason: 'no way to retry');
      await tester.tap(retry.first);
      await tester.pumpAndSettle();

      expect(chat.calls.where((c) => c == 'conversations'), hasLength(2));
      expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    });

    testWidgets('a slow load shows progress, not an empty list', (
      tester,
    ) async {
      final chat = ChatFake(latency: const Duration(milliseconds: 200))
        ..conversationsResult = const Ok([withBob]);
      final container = _scope(chat);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationList()),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(guidance, findsNothing, reason: 'not empty — still loading');

      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    });

    testWidgets('tapping a conversation opens it and popping closes it', (
      tester,
    ) async {
      final chat = ChatFake()..conversationsResult = const Ok([withBob]);
      final container = await pump(tester, chat);
      expect(container.read(openConversationProvider), isNull);

      await tester.tap(find.byKey(const ValueKey('conversation-c1')));
      await tester.pumpAndSettle();

      expect(find.byType(MessageScreen), findsOneWidget);
      expect(container.read(openConversationProvider), 'c1');

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        container.read(openConversationProvider),
        isNull,
        reason: 'the Realtime subscription must not outlive the screen',
      );
      expect(
        chat.canceledSubscriptions,
        greaterThan(0),
        reason: 'the subscription was left open after the screen was popped',
      );
    });

    testWidgets('new chat lists the other members and starts one', (
      tester,
    ) async {
      final chat = ChatFake()
        ..membersResult = const Ok([bob])
        ..startResult = const Ok('c-new');
      final container = await pump(tester, chat);

      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('member-u2')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('member-u2')));
      await tester.pumpAndSettle();

      expect(chat.started, ['u2']);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(container.read(openConversationProvider), 'c-new');
    });

    testWidgets('a failed start shows its reason and stays put', (
      tester,
    ) async {
      final chat = ChatFake()
        ..membersResult = const Ok([bob])
        ..startResult = const Err(DeniedFailure());
      final container = await pump(tester, chat);

      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('member-u2')));
      await tester.pumpAndSettle();

      expect(find.byType(MessageScreen), findsNothing);
      expect(container.read(openConversationProvider), isNull);
      expect(find.textContaining('Not allowed'), findsAtLeastNWidgets(1));
      expectNoRawException(tester);
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('home embeds the conversation list', (tester) async {
      final chat = ChatFake()..conversationsResult = const Ok([withBob]);
      await pump(tester, chat, home: const HomeScreen(member: me));

      expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-menu')), findsOneWidget);
    });
  });

  group('message screen', () {
    testWidgets('a failed load shows the reason, not a spinner', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = const Err(
          NetworkFailure('messages are unavailable'),
        );
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      expect(find.textContaining('messages are unavailable'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expectNoRawException(tester);
    });

    testWidgets('mine and theirs are drawn on different sides', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([
          msg('m1', body: 'mine', from: me.userId),
          msg('m2', body: 'theirs', from: bob.userId, minute: 1),
        ]);
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      final mine = tester
          .getCenter(find.byKey(const ValueKey('message-m1')))
          .dx;
      final theirs = tester
          .getCenter(find.byKey(const ValueKey('message-m2')))
          .dx;
      expect(
        (mine - theirs).abs(),
        greaterThan(16),
        reason: 'the sender must be readable from the layout alone',
      );
    });

    testWidgets('the composer refuses whitespace without calling out', (
      tester,
    ) async {
      final chat = ChatFake();
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        '   \n ',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('composer-send')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(chat.sent, isEmpty, reason: 'an empty body reached the database');
      expect(composerText(tester), '   \n ');
    });

    testWidgets('a successful send clears the composer', (tester) async {
      final chat = ChatFake();
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'hello there',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(chat.sent.single.conversationId, 'c1');
      expect(chat.sent.single.body, 'hello there');
      expect(composerText(tester), isEmpty);
    });

    testWidgets('a failed send keeps the text and shows the reason', (
      tester,
    ) async {
      final chat = ChatFake()
        ..sendResult = const Err(NetworkFailure('the server refused it'));
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'worth keeping',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(
        composerText(tester),
        'worth keeping',
        reason: 'losing what someone typed is a defect',
      );
      expect(
        find.textContaining('the server refused it'),
        findsAtLeastNWidgets(1),
      );
      expectNoRawException(tester);
      // Let the SnackBar timer expire inside the test.
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('subscribes before its first read', (tester) async {
      final chat = ChatFake()..holdSubscription();
      final container = _scope(chat);
      container.read(openConversationProvider.notifier).open('c1');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: MessageScreen(title: 'Bob')),
        ),
      );
      await tester.pump();

      expect(chat.calls, [
        'incoming:c1',
      ], reason: 'a read before the subscription is confirmed loses messages');
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: 'an unconfirmed subscription is still loading',
      );

      chat.confirmSubscription();
      await tester.pumpAndSettle();
      expect(chat.calls, ['incoming:c1', 'messages:c1']);
    });

    testWidgets('a message arriving after the screen is built appears', (
      tester,
    ) async {
      final chat = ChatFake()..messagesResult = Ok([msg('m1', body: 'first')]);
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      chat.deliver(msg('m2', body: 'later', from: bob.userId, minute: 5));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('message-m2')), findsOneWidget);
      expect(find.text('later'), findsOneWidget);
    });

    testWidgets('a message arriving during the first read is not lost', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', body: 'first')])
        ..holdMessages();
      final container = _scope(chat);
      container.read(openConversationProvider.notifier).open('c1');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: MessageScreen(title: 'Bob')),
        ),
      );
      await tester.pump();

      // Delivered while the initial read is still in flight: the subscription
      // is live, so this must survive the read landing on top of it.
      chat.deliver(msg('m2', body: 'raced', from: bob.userId, minute: 5));
      chat.releaseMessages();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-m2')),
        findsOneWidget,
        reason: 'the initial read overwrote a Realtime message',
      );
    });

    testWidgets('a duplicate delivery is not shown twice', (tester) async {
      final chat = ChatFake()..messagesResult = Ok([msg('m1', body: 'first')]);
      await pump(
        tester,
        chat,
        home: const MessageScreen(title: 'Bob'),
        open: 'c1',
      );

      final echo = msg('m2', body: 'echo', from: bob.userId, minute: 5);
      chat.deliver(echo);
      chat.deliver(echo);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('message-m2')), findsOneWidget);
    });
  });
}

// Widget tests for replying and forwarding: the long-press card's offer,
// the reply bar, the quoted bubble, and the forward picker. Written from the
// contract -- what a member sees and what the repository is asked to do --
// never how the widgets are built.
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
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String conversation = 'c1',
  DateTime? createdAt,
  String? replyTo,
  bool forwarded = false,
  MessageDeletion? deletion,
  bool pending = false,
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: createdAt ?? DateTime.now(),
  replyTo: replyTo,
  forwarded: forwarded,
  deletion: deletion,
  localImage: pending ? pngBytes : null,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> _scope(ChatFake chat) => settled(
  ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  ),
);

Future<ProviderContainer> pump(WidgetTester tester, ChatFake chat) async {
  final container = await _scope(chat);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  // Update 1 slice 7: the long-press card is the only place actions are
  // offered (the swipe row is gone). Its rule (menuMessageActions): delete
  // for me on any stored message, delete for everyone only on your own.
  group('what a long-press offers', () {
    testWidgets('a stored message from someone else offers reply, forward '
        'and delete for me only', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-forward')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-delete-for-me')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('menu-delete-for-everyone')),
        findsNothing,
      );
    });

    testWidgets('your own stored message under 6h offers all of them', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-forward')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-delete-for-me')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('menu-delete-for-everyone')),
        findsOneWidget,
      );
    });

    testWidgets('a pending message offers nothing', (tester) async {
      // A pending photo's own "uploading" spinner animates forever, so this
      // one test settles with a bounded number of frames rather than
      // pumpAndSettle, which would time out waiting for it to stop.
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId, pending: true)]);
      final container = await _scope(chat);
      container.read(openConversationProvider.notifier).open('c1');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MessageScreen(title: 'Bob'),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byKey(const ValueKey('menu-reply')), findsNothing);
      expect(find.byKey(const ValueKey('menu-forward')), findsNothing);
      expect(find.byKey(const ValueKey('menu-delete-for-me')), findsNothing);
      expect(find.byKey(const ValueKey('message-menu')), findsNothing);
    });

    testWidgets(
      'a deleted message offers no reply, forward or edit, even to its sender',
      (tester) async {
        final chat = ChatFake()
          ..messagesResult = Ok([
            msg(
              'm1',
              from: me.userId,
              body: '',
              deletion: MessageDeletion.placeholder,
            ),
          ]);
        await pump(tester, chat);

        await tester.longPress(find.byKey(const ValueKey('message-m1')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('menu-reply')), findsNothing);
        expect(find.byKey(const ValueKey('menu-forward')), findsNothing);
        expect(find.byKey(const ValueKey('menu-edit')), findsNothing);
      },
    );
  });

  group('replying', () {
    testWidgets('reply-bar names the sender and quotes the message', (
      tester,
    ) async {
      final chat = ChatFake()
        ..membersResult = const Ok([bob])
        ..messagesResult = Ok([
          msg('m1', from: bob.userId, body: 'see you then'),
        ]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
      expect(find.text('Replying to Bob'), findsOneWidget);
      expect(find.text('see you then'), findsWidgets);
    });

    testWidgets('replying to your own message says "Replying to You"', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: me.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();

      expect(find.text('Replying to You'), findsOneWidget);
    });

    testWidgets('reply-cancel clears the reply bar', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reply-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
    });

    testWidgets('sending a reply sends replyTo and clears the bar', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId)]);
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'sure!',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(chat.sent.single.replyTo, 'm1');
      expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
    });

    testWidgets('the new bubble quotes the original message\'s text', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', from: bob.userId, body: 'lunch?')])
        ..sendResult = Ok(
          msg('m2', from: me.userId, body: 'sure!', replyTo: 'm1'),
        );
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-reply')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'sure!',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('quote-m2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quote-m2')),
          matching: find.text('lunch?'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('quoting a deleted message shows "This message was deleted"', (
      tester,
    ) async {
      final chat = ChatFake()
        ..history['c1'] = [
          msg(
            'm1',
            from: bob.userId,
            body: '',
            deletion: MessageDeletion.placeholder,
          ),
          msg('m2', from: me.userId, body: 'ok', replyTo: 'm1'),
        ];
      await pump(tester, chat);

      expect(find.byKey(const ValueKey('quote-m2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quote-m2')),
          matching: find.text('This message was deleted'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'quoting a message this screen never loaded shows "Original message"',
      (tester) async {
        // m2 replies to m1, but m1 is not part of this screen's own history
        // -- e.g. it scrolled out, or was never paged in.
        final chat = ChatFake()
          ..history['c1'] = [
            msg('m2', from: me.userId, body: 'ok', replyTo: 'm0'),
          ];
        await pump(tester, chat);

        expect(find.byKey(const ValueKey('quote-m2')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('quote-m2')),
            matching: find.text('Original message'),
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('forwarding', () {
    ChatFake chatWithConversations() => ChatFake()
      ..conversationsResult = const Ok([
        Conversation(id: 'c1', title: 'Bob'),
        Conversation(id: 'c2', title: 'Work'),
        Conversation(id: 'c3', title: 'Family'),
      ])
      ..messagesResult = Ok([
        msg('m1', from: bob.userId, body: 'look at this'),
      ]);

    testWidgets('the picker excludes the open conversation', (tester) async {
      final chat = chatWithConversations();
      await pump(tester, chat);

      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('forward-c1')), findsNothing);
      expect(find.byKey(const ValueKey('forward-c2')), findsOneWidget);
      expect(find.byKey(const ValueKey('forward-c3')), findsOneWidget);
    });

    testWidgets('Send is disabled until a chat is picked, then labelled with '
        'the count', (tester) async {
      final chat = chatWithConversations();
      await pump(tester, chat);
      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();

      final sendButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('forward-send')),
      );
      expect(sendButton.onPressed, isNull);
      expect(find.text('Send'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('forward-c2')));
      await tester.pumpAndSettle();
      expect(find.text('Send (1)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('forward-c3')));
      await tester.pumpAndSettle();
      expect(find.text('Send (2)'), findsOneWidget);
    });

    testWidgets('sending to one chat calls forward and shows "Forwarded"', (
      tester,
    ) async {
      final chat = chatWithConversations();
      await pump(tester, chat);
      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('forward-c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();

      expect(chat.forwarded.single.messageId, 'm1');
      expect(chat.forwarded.single.conversationIds, ['c2']);
      expect(find.text('Forwarded'), findsOneWidget);
      await drainNotice(tester);
    });

    testWidgets('sending to two chats shows "Forwarded to 2 chats"', (
      tester,
    ) async {
      final chat = chatWithConversations();
      await pump(tester, chat);
      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('forward-c2')));
      await tester.tap(find.byKey(const ValueKey('forward-c3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();

      expect(chat.forwarded.single.conversationIds, ['c2', 'c3']);
      expect(find.text('Forwarded to 2 chats'), findsOneWidget);
      await drainNotice(tester);
    });

    testWidgets('a refused forward shows its reason', (tester) async {
      final chat = chatWithConversations()
        ..forwardResult = const Err(ProviderFailure('not your chat'));
      await pump(tester, chat);
      await tester.longPress(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('forward-c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();

      expect(find.textContaining('not your chat'), findsOneWidget);
      await drainNotice(tester);
    });

    testWidgets('a forwarded message is marked "Forwarded" in the bubble', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([
          msg('m1', from: bob.userId, body: 'fyi', forwarded: true),
        ]);
      await pump(tester, chat);

      expect(find.byKey(const ValueKey('forwarded-m1')), findsOneWidget);
      expect(find.text('Forwarded'), findsOneWidget);
    });
  });

  // 0.30.10: forwarding is a full page (forward-page), not a sheet. It names
  // what is being forwarded (forward-strip), searches the chats, offers the
  // people you have no chat with yet (forward-person-<id>), and its Send
  // creates those chats first; if one cannot be created nothing is sent.
  group('the forward page (0.30.10)', () {
    const cleo = Member(userId: 'u3', displayName: 'Cleo');
    Finder byKey(String k) => find.byKey(ValueKey(k));

    ChatFake world() => ChatFake()
      ..conversationsResult = const Ok([
        Conversation(id: 'c1', other: bob),
        Conversation(id: 'c2', title: 'Work'),
        Conversation(id: 'c3', title: 'Family'),
      ])
      ..membersResult = const Ok([bob, cleo])
      ..messagesResult = Ok([
        msg('m1', from: bob.userId, body: 'look at this'),
      ]);

    Future<void> openPage(WidgetTester t, ChatFake chat) async {
      await pump(t, chat);
      await t.longPress(byKey('message-m1'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-forward'));
      // The page is there on the first frame after the tap: no network wait.
      // Two frames: the tap's own frame and the push's.
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      expect(byKey('forward-page'), findsOneWidget, reason: 'not at once');
      await t.pumpAndSettle();
    }

    String textUnder(String k) => find
        .descendant(of: byKey(k), matching: find.byType(RichText))
        .evaluate()
        .map((e) => (e.widget as RichText).text.toPlainText())
        .join(' ');

    testWidgets('names what is forwarded in the strip', (t) async {
      await openPage(t, world());
      final strip = textUnder('forward-strip');
      expect(strip, contains('Forwarding:'));
      expect(strip, contains('look at this'));
    });

    testWidgets('search narrows the chats; nothing matching shows the empty '
        'line', (t) async {
      await openPage(t, world());
      await t.enterText(byKey('forward-search'), 'wor');
      await t.pumpAndSettle();
      expect(byKey('forward-c2'), findsOneWidget);
      expect(byKey('forward-c3'), findsNothing);
      expect(byKey('forward-empty'), findsNothing);

      await t.enterText(byKey('forward-search'), 'zzzz');
      await t.pumpAndSettle();
      expect(byKey('forward-c2'), findsNothing);
      expect(byKey('forward-empty'), findsOneWidget);
    });

    testWidgets('someone you have no chat with is offered as a person; '
        'Send starts that chat first and forwards into it', (t) async {
      final chat = world()..forwardResult = const Ok(null);
      await openPage(t, chat);
      // Bob already has a chat with you (the open one): not a person row.
      expect(byKey('forward-person-u2'), findsNothing);
      await t.scrollUntilVisible(
        byKey('forward-person-u3'),
        100,
        scrollable: find
            .descendant(
              of: byKey('forward-page'),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await t.tap(byKey('forward-person-u3'));
      await t.pumpAndSettle();
      expect(find.text('Send (1)'), findsOneWidget);
      await t.tap(byKey('forward-send'));
      await t.pumpAndSettle();

      expect(chat.started, ['u3']);
      expect(chat.forwarded.single.conversationIds, ['c-new']);
      expect(byKey('forward-page'), findsNothing, reason: 'page stayed');
      await drainNotice(t);
    });

    testWidgets('a chat that cannot be started: its reason is shown and '
        'nothing is forwarded, not even to the ticked chat', (t) async {
      final chat = world()
        ..startResult = const Err(ProviderFailure('cannot reach Cleo'));
      await openPage(t, chat);
      await t.tap(byKey('forward-c2'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        byKey('forward-person-u3'),
        100,
        scrollable: find
            .descendant(
              of: byKey('forward-page'),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await t.tap(byKey('forward-person-u3'));
      await t.pumpAndSettle();
      expect(find.text('Send (2)'), findsOneWidget);
      await t.tap(byKey('forward-send'));
      await t.pumpAndSettle();

      expect(chat.forwarded, isEmpty);
      expect(find.textContaining('cannot reach Cleo'), findsOneWidget);
      await drainNotice(t);
    });

    testWidgets('back closes the page and forwards nothing', (t) async {
      final chat = world();
      await openPage(t, chat);
      await t.tap(byKey('forward-c2'));
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsNothing);
      expect(chat.forwarded, isEmpty);
      expect(chat.started, isEmpty);
    });
  });
}

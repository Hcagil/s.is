// A text message is shown the moment it is sent (2026-09-28), as the member
// sees it on the real MessageScreen: the bubble with its clock at once, the
// composer emptied and still usable, the time replacing the clock when the
// server has it, and on a failure the text, reply target and one notice
// coming back -- also after leaving the chat and returning. Written from
// the contract, never from how the screen is built.
//
// Run under TZ=JST-9 like every unit test.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/sis_ui.dart';

const bob = Member(userId: 'u2', displayName: 'Bob');
const failure = NetworkFailure('Could not reach SIS just now');

Message msg(String id, {String body = 'hi', String from = 'u2'}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// The container of the test running now, for [pendingBubble].
late ProviderContainer _c;

Future<ProviderContainer> scope(HeldSendChat chat) async => _c = await settled(
  ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
  ),
);

/// The message screen over c1, opened the way the list opens it.
Future<ProviderContainer> pump(WidgetTester t, HeldSendChat chat) async {
  final c = await scope(chat);
  c.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await t.pumpAndSettle();
  return c;
}

Finder keyStarting(String prefix) => find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith(prefix);
});

/// Ids of every message still waiting in a send queue: a pending bubble is
/// keyed by the same id the server will store it under.
Set<String> _queued() => {
  for (final q in _c.read(sendQueueProvider).values)
    for (final m in q) m.id,
};
Finder _keyedFor(String prefix) => find.byWidgetPredicate((w) {
  final k = w.key;
  if (k is! ValueKey<String> || !k.value.startsWith(prefix)) return false;
  return _queued().contains(k.value.substring(prefix.length));
});
Finder get pendingBubble => _keyedFor('message-');
Finder get pendingTime => _keyedFor('time-');
final clock = find.byIcon(Icons.schedule_rounded);
Finder bubble(String id) => find.byKey(ValueKey('message-$id'));
final field = find.byKey(const ValueKey('composer-field'));
final send = find.byKey(const ValueKey('composer-send'));
final replyAction = find.byKey(const ValueKey('menu-reply'));
final replyBar = find.byKey(const ValueKey('reply-bar'));
final editAction = find.byKey(const ValueKey('menu-edit'));
final editBar = find.byKey(const ValueKey('edit-bar'));

String composerText(WidgetTester t) => t
    .widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    )
    .controller
    .text;

/// Every piece of text rendered under [of], in tree order, space-joined.
String textIn(WidgetTester t, Finder of) => [
  for (final e
      in find.descendant(of: of, matching: find.byType(RichText)).evaluate())
    (e.widget as RichText).text.toPlainText(),
].join(' ');

Future<void> type(WidgetTester t, String text) async {
  await t.enterText(field, text);
  await t.pump();
}

/// Types [text] and taps send, then exactly one frame.
Future<void> sendText(WidgetTester t, String text) async {
  await type(t, text);
  await t.tap(send);
  await t.pump();
}

Future<void> reply(WidgetTester t, String id) async {
  await t.tap(bubble(id));
  await t.pumpAndSettle();
  await t.tap(replyAction);
  await t.pumpAndSettle();
}

const yellow = Color(0xFFFFD54F);

/// The colours of the border drawn around the bubble at [of].
Set<Color> edgeColours(WidgetTester t, Finder of) {
  expect(of, findsOneWidget);
  final box =
      find
              .descendant(
                of: of,
                matching: find.byType(DecoratedBox),
                matchRoot: true,
              )
              .evaluate()
              .first
              .widget
          as DecoratedBox;
  final b = (box.decoration as BoxDecoration).border as Border?;
  if (b == null) return {};
  return {b.top.color, b.right.color, b.bottom.color, b.left.color};
}

String hhmm(DateTime at) {
  final l = at.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

void main() {
  group('tapping send', () {
    testWidgets('shows the message at once with a clock, empties the field, '
        'and send can be tapped again', (t) async {
      final chat = HeldSendChat()..history['c1'] = [msg('m1')];
      await pump(t, chat);

      await sendText(t, 'hello there');

      expect(pendingBubble, findsOneWidget, reason: 'shown before any answer');
      expect(textIn(t, pendingBubble), contains('hello there'));
      final mark = find.descendant(
        of: pendingTime,
        matching: clock,
        matchRoot: true,
      );
      expect(mark, findsOneWidget, reason: 'the clock sits in the time slot');
      expect(t.widget<Icon>(mark).size, 12);
      expect(composerText(t), isEmpty);

      await sendText(t, 'and again');
      expect(
        pendingBubble,
        findsNWidgets(2),
        reason: 'send stays usable while the first is on its way',
      );
      expect(composerText(t), isEmpty);
      expect(chat.asked.map((a) => a.body), [
        'hello there',
      ], reason: 'the second waits for the first');

      chat.ok(0);
      await t.pump();
      chat.ok(1);
      await t.pumpAndSettle();
    });

    testWidgets('the clock gives way to the time once the server has it', (
      t,
    ) async {
      final chat = HeldSendChat()..history['c1'] = [msg('m1')];
      await pump(t, chat);

      await sendText(t, 'hello there');
      expect(clock, findsOneWidget);

      chat.ok(0);
      await t.pumpAndSettle();

      expect(clock, findsNothing);
      expect(pendingBubble, findsNothing);
      final id = chat.asked.single.id;
      expect(textIn(t, bubble(id)), contains('hello there'));
      expect(
        textIn(t, find.byKey(ValueKey('time-$id'))),
        contains(hhmm(chat.asked.single.stored.createdAt)),
      );
    });

    testWidgets('a message on its way has no yellow unread edge; once stored '
        'and unread, it has', (t) async {
      // Bob shares read receipts and has read nothing: my stored messages
      // are unread.
      final chat = HeldSendChat()
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
      await pump(t, chat);

      await sendText(t, 'hello there');
      expect(edgeColours(t, pendingBubble), isNot(contains(yellow)));

      chat.ok(0);
      await t.pumpAndSettle();
      expect(edgeColours(t, bubble(chat.asked.single.id)), {
        yellow,
      }, reason: 'control: the stored, unread message does show the edge');
    });
  });

  group('a failed send', () {
    testWidgets('puts the text back in an empty field, with one notice', (
      t,
    ) async {
      final chat = HeldSendChat()..history['c1'] = [msg('m1')];
      await pump(t, chat);

      await sendText(t, 'hello there');
      chat.fail(0, failure);
      await t.pumpAndSettle();

      expect(composerText(t), 'hello there');
      expect(pendingBubble, findsNothing);
      expect(clock, findsNothing);
      expect(notice, findsOneWidget);
      expect(noticeSaying(failure.message), findsOneWidget);
      await drainNotice(t);
    });

    testWidgets('puts the text back ahead of what was typed since', (t) async {
      final chat = HeldSendChat();
      await pump(t, chat);

      await sendText(t, 'first');
      await type(t, 'draft');
      chat.fail(0, failure);
      await t.pumpAndSettle();

      expect(composerText(t), 'first\ndraft');
      await drainNotice(t);
    });

    testWidgets('two queued sends come back in typed order, with one notice', (
      t,
    ) async {
      final chat = HeldSendChat();
      await pump(t, chat);

      await sendText(t, 'a');
      await sendText(t, 'b');
      await type(t, 'c');
      chat.fail(0, failure);
      await t.pumpAndSettle();

      expect(composerText(t), 'a\nb\nc');
      expect(pendingBubble, findsNothing);
      expect(notice, findsOneWidget);
      expect(chat.asked, hasLength(1), reason: 'b was never tried');
      await drainNotice(t);
    });

    testWidgets('brings the reply bar back, and a resend replies again', (
      t,
    ) async {
      final chat = HeldSendChat()
        ..history['c1'] = [msg('m1', body: 'where are you')];
      await pump(t, chat);

      await reply(t, 'm1');
      expect(replyBar, findsOneWidget);
      await sendText(t, 'on my way');
      expect(replyBar, findsNothing, reason: 'the reply went with the message');

      chat.fail(0, failure);
      await t.pumpAndSettle();

      expect(replyBar, findsOneWidget);
      expect(textIn(t, replyBar), contains('where are you'));
      expect(composerText(t), 'on my way');
      await drainNotice(t);

      await t.tap(send);
      await t.pump();
      await t.pump();
      expect(chat.asked, hasLength(2));
      expect(chat.asked.last.replyTo, 'm1');
      chat.ok(1);
      await t.pumpAndSettle();
    });

    testWidgets('after leaving the chat: coming back finds the text, the reply '
        'and the notice', (t) async {
      final chat = HeldSendChat()
        ..history['c1'] = [msg('m1', body: 'where are you')]
        ..conversationsResult = const Ok([Conversation(id: 'c1', other: bob)]);
      final c = await scope(chat);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: sisTheme(Brightness.light),
            home: const ConversationList(),
          ),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('conversation-c1')));
      await t.pumpAndSettle();
      await reply(t, 'm1');
      await sendText(t, 'on my way');
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen), findsNothing);

      chat.fail(0, failure);
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('conversation-c1')));
      await t.pumpAndSettle();

      expect(composerText(t), 'on my way');
      expect(replyBar, findsOneWidget);
      expect(textIn(t, replyBar), contains('where are you'));
      expect(pendingBubble, findsNothing);
      expect(notice, findsOneWidget);
      expect(noticeSaying(failure.message), findsOneWidget);
      await drainNotice(t);
    });
  });

  testWidgets('saving an edit still waits for the server, as before', (
    t,
  ) async {
    final chat = HeldSendChat()
      ..history['c1'] = [msg('m1', body: 'see you at 5', from: 'u1')]
      ..holdEdit();
    await pump(t, chat);

    await t.tap(bubble('m1'));
    await t.pumpAndSettle();
    await t.tap(editAction);
    await t.pumpAndSettle();
    await sendText(t, 'see you at 6');
    await t.pump();

    expect(chat.asked, isEmpty, reason: 'an edit is never a new message');
    expect(pendingBubble, findsNothing);
    expect(clock, findsNothing);
    expect(editBar, findsOneWidget, reason: 'the edit waits for its answer');
    expect(composerText(t), 'see you at 6');

    chat.releaseEdit();
    await t.pumpAndSettle();

    expect(editBar, findsNothing);
    expect(composerText(t), isEmpty);
    expect(textIn(t, bubble('m1')), contains('see you at 6'));
    expect(bubble('m1'), findsOneWidget);
  });
}

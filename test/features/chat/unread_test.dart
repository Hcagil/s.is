// Unread counts and group sender names, written from the contract:
// Conversation.unread / withPreview / read, startsRun, the list controller's
// counting and markRead, opening a conversation, the list badge, sender names
// in a group, and the avatar tint. Run under TZ=JST-9 like every unit test.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

DateTime at(int minute) => DateTime.utc(2026, 9, 22, 12, minute);

Conversation conv(String id, int minute, {Member? other, int unread = 0}) =>
    Conversation(
      id: id,
      other: other ?? bob,
      lastMessage: 'old $id',
      lastMessageAt: at(minute),
      lastSenderId: (other ?? bob).userId,
      unread: unread,
    );

Message msg(
  String conversation,
  int minute, {
  String id = '',
  String body = 'new',
  String from = 'u2',
}) => Message(
  id: id.isEmpty ? '$conversation-$minute-$from' : id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: at(minute),
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

ProviderContainer scope(ChatFake chat) => ProviderContainer.test(
  overrides: [
    chatRepositoryProvider.overrideWithValue(chat),
    presenceRepositoryProvider.overrideWithValue(PresenceFake()),
    sessionControllerProvider.overrideWith(_SignedIn.new),
  ],
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

Conversation row(ProviderContainer c, String id) =>
    c.read(conversationListProvider).requireValue.firstWhere((x) => x.id == id);

Future<ProviderContainer> loaded(ChatFake chat) async {
  final c = scope(chat);
  c.listen(conversationListProvider, (_, _) {});
  // The session resolves first, so "mine" is known before anything arrives.
  await c.read(sessionControllerProvider.future);
  await c.read(conversationListProvider.future);
  await settle();
  return c;
}

void main() {
  group('Conversation', () {
    final m = msg('c1', 40, body: 'hello', from: 'u2');

    test('unread defaults to 0', () {
      expect(const Conversation(id: 'c1').unread, 0);
    });

    test('withPreview counts only when asked', () {
      final c = conv('c1', 30, unread: 2);
      expect(c.withPreview(m).unread, 2, reason: 'counts defaults to false');
      expect(c.withPreview(m, counts: false).unread, 2);
      expect(c.withPreview(m, counts: true).unread, 3);
      final moved = c.withPreview(m, counts: true);
      expect(moved.lastMessage, 'hello');
      expect(moved.lastMessageAt, at(40));
      expect(moved.lastSenderId, 'u2');
      expect(moved.other, bob);
    });

    test('read() zeroes unread and keeps everything else', () {
      final c = Conversation(
        id: 'g1',
        title: 'Trip',
        other: bob,
        lastMessage: 'boots',
        lastMessageAt: at(5),
        lastSenderId: 'u3',
        unread: 7,
      );
      final r = c.read();
      expect(r.unread, 0);
      expect(r.id, 'g1');
      expect(r.title, 'Trip');
      expect(r.other, bob);
      expect(r.lastMessage, 'boots');
      expect(r.lastMessageAt, at(5));
      expect(r.lastSenderId, 'u3');
      expect(c.unread, 7, reason: 'read() must return a copy');
    });
  });

  group('startsRun', () {
    final list = [
      msg('g', 1, from: 'a'),
      msg('g', 2, from: 'a'),
      msg('g', 3, from: 'b'),
      msg('g', 4, from: 'a'),
      msg('g', 5, from: 'a'),
    ];

    test('the first message starts a run', () {
      expect(startsRun(list, 0), isTrue);
      expect(startsRun([msg('g', 1)], 0), isTrue);
    });

    test('a run breaks exactly where the sender changes', () {
      expect(
        [for (var i = 0; i < list.length; i++) startsRun(list, i)],
        [true, false, true, true, false],
      );
    });
  });

  group('ConversationListController unread', () {
    test('the first read carries the server counts', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30, unread: 4), conv('c2', 20)]);
      final c = await loaded(chat);
      expect(row(c, 'c1').unread, 4);
      expect(row(c, 'c2').unread, 0);
    });

    test('a message from someone else counts in its conversation', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30, unread: 1), conv('c2', 20)]);
      final c = await loaded(chat);

      chat.deliver(msg('c1', 40));
      await settle();
      chat.deliver(msg('c1', 41, from: 'u3'));
      await settle();

      expect(row(c, 'c1').unread, 3);
      expect(row(c, 'c2').unread, 0, reason: 'another conversation counted');
    });

    test('my own message does not count', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = await loaded(chat);

      chat.deliver(msg('c1', 40, from: me.userId));
      await settle();

      expect(row(c, 'c1').lastSenderId, me.userId, reason: 'not delivered');
      expect(row(c, 'c1').unread, 0);
    });

    test('a message in the open conversation does not count', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
      final c = await loaded(chat);
      c.read(openConversationProvider.notifier).open('c1');

      chat.deliver(msg('c1', 40, body: 'seen'));
      chat.deliver(msg('c2', 41));
      await settle();

      expect(row(c, 'c1').lastMessage, 'seen', reason: 'not delivered');
      expect(row(c, 'c1').unread, 0, reason: 'the open conversation counted');
      expect(row(c, 'c2').unread, 1, reason: 'a closed one must still count');
    });

    test('once closed, the conversation counts again', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = await loaded(chat);
      c.read(openConversationProvider.notifier).open('c1');
      chat.deliver(msg('c1', 40));
      await settle();
      c.read(openConversationProvider.notifier).close();
      chat.deliver(msg('c1', 41));
      await settle();

      expect(row(c, 'c1').unread, 1);
    });

    test('a duplicate delivery counts once', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = await loaded(chat);

      final m = msg('c1', 40);
      chat.deliver(m);
      await settle();
      chat.deliver(m);
      await settle();

      expect(row(c, 'c1').unread, 1, reason: 'the same message counted twice');
    });

    test(
      'a late delivery of a message the read already had does not count',
      () async {
        // The server's count already includes everything up to the preview.
        final chat = ChatFake()
          ..conversationsResult = Ok([conv('c1', 30, unread: 2)]);
        final c = await loaded(chat);

        chat.deliver(msg('c1', 10, body: 'late'));
        await settle();

        expect(row(c, 'c1').unread, 2);
      },
    );

    test(
      'a new conversation takes its count from the server, not +1',
      () async {
        final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
        final c = await loaded(chat);

        // The server already counts the message that announces it.
        chat.conversationsResult = Ok([
          conv('c9', 50, other: cem, unread: 1),
          conv('c1', 30),
        ]);
        chat.deliver(msg('c9', 50, from: 'u3'));
        await settle();

        expect(
          row(c, 'c9').unread,
          1,
          reason: 'the announcing message double-counted',
        );
      },
    );

    test('a message during the first read is counted once', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)])
        ..holdList();
      final c = scope(chat);
      c.listen(conversationListProvider, (_, _) {});
      await settle();
      expect(chat.calls, contains('conversations'), reason: 'read in flight');

      // After the read's snapshot: the server count in it does not include it.
      chat.deliver(msg('c2', 40));
      await settle();
      chat.releaseList();
      await c.read(conversationListProvider.future);
      await settle();

      expect(row(c, 'c2').unread, 1);
    });

    test(
      'markRead asks the repository and zeroes only that conversation',
      () async {
        final chat = ChatFake()
          ..conversationsResult = Ok([
            conv('c1', 30, unread: 3),
            conv('c2', 20, unread: 2),
          ]);
        final c = await loaded(chat);

        await c.read(conversationListProvider.notifier).markRead('c1');
        await settle();

        expect(chat.markedRead, ['c1']);
        expect(row(c, 'c1').unread, 0);
        expect(row(c, 'c1').lastMessage, 'old c1');
        expect(row(c, 'c1').other, bob);
        expect(row(c, 'c2').unread, 2);
      },
    );

    test('markRead that fails leaves the count', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30, unread: 3)])
        ..markReadResult = const Err(NetworkFailure('offline'));
      final c = await loaded(chat);

      await c.read(conversationListProvider.notifier).markRead('c1');
      await settle();

      expect(chat.markedRead, ['c1']);
      expect(
        row(c, 'c1').unread,
        3,
        reason: 'cleared although the server did not',
      );
      expect(c.read(conversationListProvider).hasError, isFalse);
    });

    test('markRead waits for the server before clearing', () async {
      final chat = ChatFake(latency: const Duration(milliseconds: 50))
        ..conversationsResult = Ok([conv('c1', 30, unread: 3)]);
      final c = await loaded(chat);

      final pending = c.read(conversationListProvider.notifier).markRead('c1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        row(c, 'c1').unread,
        3,
        reason: 'cleared before the server answered',
      );
      await pending;
      await settle();
      expect(row(c, 'c1').unread, 0);
    });
  });

  group('list badge', () {
    Future<ProviderContainer> pump(WidgetTester tester, ChatFake chat) async {
      final container = scope(chat);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationList()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    Finder badgeText(String id, String text) => find.descendant(
      of: find.byKey(ValueKey('unread-$id')),
      matching: find.text(text),
      matchRoot: true,
    );

    Color? painted(WidgetTester t, String key) {
      final f = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(RichText),
        matchRoot: true,
      );
      final p = t.renderObject<RenderParagraph>(f.first);
      Color? c = p.text.style?.color;
      p.text.visitChildren((span) {
        c = span.style?.color ?? c;
        return false;
      });
      return c;
    }

    List<Conversation> today(List<int> counts) => [
      for (var i = 0; i < counts.length; i++)
        Conversation(
          id: 'c$i',
          other: Member(userId: 'u${i + 2}', displayName: 'P$i'),
          lastMessage: 'hi',
          lastMessageAt: DateTime.now().toUtc(),
          lastSenderId: 'u${i + 2}',
          unread: counts[i],
        ),
    ];

    testWidgets('shows the count, 99+ above 99, and nothing at 0', (t) async {
      final chat = ChatFake()..conversationsResult = Ok(today([3, 99, 100, 0]));
      await pump(t, chat);

      expect(badgeText('c0', '3'), findsOneWidget);
      expect(badgeText('c1', '99'), findsOneWidget);
      expect(badgeText('c2', '99+'), findsOneWidget);
      expect(find.text('100'), findsNothing);
      expect(find.byKey(const ValueKey('unread-c3')), findsNothing);
    });

    testWidgets('an unread conversation has its time in the primary colour', (
      t,
    ) async {
      final chat = ChatFake()..conversationsResult = Ok(today([2, 0]));
      await pump(t, chat);

      final primary = Theme.of(
        t.element(find.byKey(const ValueKey('preview-time-c0'))),
      ).colorScheme.primary;
      expect(painted(t, 'preview-time-c0'), primary);
      expect(
        painted(t, 'preview-time-c1'),
        isNot(primary),
        reason: 'a read conversation looks the same as an unread one',
      );
    });

    testWidgets('a live message from someone else shows a badge', (t) async {
      final chat = ChatFake()..conversationsResult = Ok(today([0]));
      await pump(t, chat);
      expect(find.byKey(const ValueKey('unread-c0')), findsNothing);

      chat.deliver(
        Message(
          id: 'm1',
          conversationId: 'c0',
          senderId: 'u2',
          body: 'ping',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await t.pumpAndSettle();

      expect(badgeText('c0', '1'), findsOneWidget);
    });
  });

  group('opening a conversation from the list', () {
    Future<ProviderContainer> pump(WidgetTester tester, ChatFake chat) async {
      final container = scope(chat);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationList()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    ChatFake world() => ChatFake(self: me.userId)
      ..conversationsResult = Ok([
        Conversation(
          id: 'c1',
          other: bob,
          lastMessage: 'hey',
          lastMessageAt: DateTime.now().toUtc(),
          lastSenderId: bob.userId,
        ),
      ]);

    int marks(ChatFake chat) =>
        chat.calls.where((c) => c == 'markRead:c1').length;

    testWidgets('marks it read on open', (t) async {
      final chat = world();
      await pump(t, chat);

      await t.tap(find.byKey(const ValueKey('conversation-c1')));
      await t.pumpAndSettle();

      expect(find.byType(MessageScreen), findsOneWidget);
      expect(
        marks(chat),
        greaterThanOrEqualTo(1),
        reason: 'not marked on open',
      );
    });

    testWidgets('marks it read again when popped, before the list re-reads', (
      t,
    ) async {
      final chat = world();
      await pump(t, chat);
      await t.tap(find.byKey(const ValueKey('conversation-c1')));
      await t.pumpAndSettle();
      final before = marks(chat);

      await t.pageBack();
      await t.pumpAndSettle();

      expect(marks(chat), before + 1, reason: 'not marked when popped');
      expect(
        chat.calls.lastIndexOf('markRead:c1'),
        lessThan(chat.calls.lastIndexOf('conversations')),
        reason: 'the list re-read before the conversation was marked read',
      );
      expect(find.byKey(const ValueKey('unread-c1')), findsNothing);
    });

    testWidgets('a message from someone else while open marks it read', (
      t,
    ) async {
      final chat = world();
      await pump(t, chat);
      await t.tap(find.byKey(const ValueKey('conversation-c1')));
      await t.pumpAndSettle();
      final before = marks(chat);

      chat.deliver(
        Message(
          id: 'live-1',
          conversationId: 'c1',
          senderId: bob.userId,
          body: 'are you there',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('are you there'), findsOneWidget, reason: 'not shown');
      expect(marks(chat), before + 1);

      chat.deliver(
        Message(
          id: 'live-2',
          conversationId: 'c1',
          senderId: bob.userId,
          body: 'hello?',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await t.pumpAndSettle();
      expect(marks(chat), before + 2, reason: 'each message marks it read');
    });
  });

  group('group sender names', () {
    Message m(String id, String from, int minute, String conversation) =>
        Message(
          id: id,
          conversationId: conversation,
          senderId: from,
          body: 'body $id',
          createdAt: at(minute),
        );

    Future<void> openFromList(
      WidgetTester t,
      Conversation c,
      List<Message> history,
    ) async {
      final chat = ChatFake()
        ..membersResult = const Ok([bob, cem])
        ..conversationsResult = Ok([c])
        ..messagesResult = Ok(history);
      final container = scope(chat);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationList()),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('conversation-${c.id}')));
      await t.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
    }

    Finder sender(String id) => find.byKey(ValueKey('sender-$id'));

    testWidgets('named above the first message of each run by another', (
      t,
    ) async {
      await openFromList(t, const Conversation(id: 'g7', title: 'Trip'), [
        m('m1', 'u2', 1, 'g7'),
        m('m2', 'u2', 2, 'g7'),
        m('m3', 'u1', 3, 'g7'),
        m('m4', 'u3', 4, 'g7'),
        m('m5', 'u2', 5, 'g7'),
        m('m6', 'u1', 6, 'g7'),
        m('m7', 'u1', 7, 'g7'),
      ]);

      for (final (id, name) in [('m1', 'Bob'), ('m4', 'Cem'), ('m5', 'Bob')]) {
        expect(
          find.descendant(
            of: sender(id),
            matching: find.text(name),
            matchRoot: true,
          ),
          findsOneWidget,
          reason: '$id should be headed "$name"',
        );
        expect(
          t.getTopLeft(sender(id)).dy,
          lessThan(t.getTopLeft(find.text('body $id')).dy),
          reason: 'the name must sit above the message',
        );
      }
      expect(sender('m2'), findsNothing, reason: 'same sender, same run');
      expect(sender('m3'), findsNothing, reason: 'my own message');
      expect(sender('m6'), findsNothing, reason: 'my own message');
      expect(sender('m7'), findsNothing);
    });

    testWidgets('never in a 1:1', (t) async {
      await openFromList(t, const Conversation(id: 'c1', other: bob), [
        m('m1', 'u2', 1, 'c1'),
        m('m2', 'u1', 2, 'c1'),
        m('m3', 'u2', 3, 'c1'),
      ]);
      expect(find.text('body m1'), findsOneWidget, reason: 'not rendered');
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('sender-'),
        ),
        findsNothing,
      );
    });
  });

  group('avatar tint', () {
    final anyWidget = find.byWidgetPredicate((_) => true);

    /// Fill of the nearest round thing around [inner].
    Color? roundFill(Finder inner) {
      for (final e
          in find.ancestor(of: inner, matching: anyWidget).evaluate()) {
        final c = switch (e.widget) {
          CircleAvatar(:final backgroundColor) => backgroundColor,
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle, :final color),
          ) =>
            color,
          DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, :final color),
          ) =>
            color,
          Material(shape: CircleBorder(), :final color) => color,
          Material(type: MaterialType.circle, :final color) => color,
          _ => null,
        };
        if (c != null) return c;
      }
      return null;
    }

    testWidgets('a 1:1 in the list and the same person in the picker match', (
      t,
    ) async {
      const ela = Member(userId: 'u7', displayName: 'Ela Demir');
      final chat = ChatFake()
        ..membersResult = const Ok([bob, ela])
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', other: bob, lastMessage: 'a'),
          Conversation(id: 'c2', other: ela, lastMessage: 'b'),
        ]);
      final container = scope(chat);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationList()),
        ),
      );
      await t.pumpAndSettle();

      Finder initials(String key, String text) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.text(text),
      );
      final inList = {
        'u2': roundFill(initials('conversation-c1', 'B')),
        'u7': roundFill(initials('conversation-c2', 'ED')),
      };
      expect(inList.values, everyElement(isNotNull), reason: 'no avatar found');

      await t.tap(find.text('New chat'));
      await t.pumpAndSettle();
      final inPicker = {
        'u2': roundFill(initials('member-u2', 'B')),
        'u7': roundFill(initials('member-u7', 'ED')),
      };
      expect(inPicker, inList);
    });
  });
}

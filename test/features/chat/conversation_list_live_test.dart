// The conversation list kept live: written from the contract of
// ConversationListController and the list tile, against ChatFake — a
// subscription that is not confirmed until the test says so, a read that can
// be held open, and Realtime that delivers only to a live listener.
//
// Since v0.21.4 the list is fetched while its Realtime join is still being
// set up, instead of after it (docs/DECISIONS.md 2026-09-28, "The app opens
// faster"). The group "start-up" holds the new order against JoinChat, whose
// join can take forever and whose stream keeps what arrives before listen().

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';

import '../../support/fakes.dart';
import '../../support/join_chat.dart';
import '../../support/sis_ui.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

DateTime at(int minute) => DateTime.utc(2026, 9, 22, 12, minute);

Conversation conv(String id, int minute, {Member? other, String? text}) =>
    Conversation(
      id: id,
      other: other ?? bob,
      lastMessage: text ?? 'old $id',
      lastMessageAt: at(minute),
      lastSenderId: (other ?? bob).userId,
    );

Message msg(
  String conversation,
  int minute, {
  String id = '',
  String body = 'new',
  String from = 'u2',
}) => Message(
  id: id.isEmpty ? '$conversation-$minute' : id,
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
    pushSourceProvider.overrideWithValue(PushSourceFake()),
  ],
);

/// Lets the fake's async hops and the controller's reactions run.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

List<String> ids(ProviderContainer c) =>
    c.read(conversationListProvider).requireValue.map((x) => x.id).toList();

Conversation row(ProviderContainer c, String id) =>
    c.read(conversationListProvider).requireValue.firstWhere((x) => x.id == id);

/// A container whose list is loaded and kept alive.
Future<ProviderContainer> loaded(ChatFake chat) async {
  final c = scope(chat);
  c.listen(conversationListProvider, (_, _) {});
  await c.read(conversationListProvider.future);
  await settle();
  return c;
}

void main() {
  group('ConversationListController', () {
    test(
      'a message moves its conversation to the top with its preview',
      () async {
        final chat = ChatFake()
          ..conversationsResult = Ok([
            conv('c1', 30),
            conv('c2', 20),
            conv('c3', 10, other: cem),
          ]);
        final c = await loaded(chat);

        chat.deliver(msg('c3', 40, body: 'fresh', from: 'u3'));
        await settle();

        expect(ids(c), ['c3', 'c1', 'c2']);
        final top = row(c, 'c3');
        expect(top.lastMessage, 'fresh');
        expect(top.lastMessageAt, at(40));
        expect(top.lastSenderId, 'u3');
        expect(top.other, cem, reason: 'who the chat is with must not change');
        expect(row(c, 'c1').lastMessage, 'old c1', reason: 'others untouched');
      },
    );

    test('an own message updates the preview too', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
      final c = await loaded(chat);

      chat.deliver(msg('c2', 35, body: 'mine', from: 'u1'));
      await settle();

      expect(ids(c), ['c2', 'c1']);
      expect(row(c, 'c2').lastSenderId, 'u1');
    });

    test('an older message never replaces a newer preview', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
      final c = await loaded(chat);

      chat.deliver(msg('c2', 5, body: 'late'));
      await settle();

      expect(ids(c), ['c1', 'c2'], reason: 'a late message reordered the list');
      expect(row(c, 'c2').lastMessage, 'old c2');
      expect(row(c, 'c2').lastMessageAt, at(20));
    });

    test('a duplicate delivery is harmless', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
      final c = await loaded(chat);

      final m = msg('c2', 40, body: 'once');
      chat.deliver(m);
      await settle();
      chat.deliver(msg('c1', 45, body: 'later'));
      await settle();
      chat.deliver(m);
      await settle();

      expect(ids(c), ['c1', 'c2']);
      expect(row(c, 'c1').lastMessage, 'later');
      expect(row(c, 'c2').lastMessage, 'once');
      expect(ids(c), hasLength(2), reason: 'a conversation was listed twice');
    });

    test('a message in an unknown conversation re-reads the list', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = await loaded(chat);
      final readsBefore = chat.calls.where((x) => x == 'conversations').length;

      // Someone started a conversation with this member; the server has it.
      chat.conversationsResult = Ok([
        conv('c9', 50, other: cem, text: 'hello there'),
        conv('c1', 30),
      ]);
      chat.deliver(msg('c9', 50, body: 'hello there', from: 'u3'));
      await settle();

      expect(
        chat.calls.where((x) => x == 'conversations').length,
        greaterThan(readsBefore),
      );
      expect(ids(c), ['c9', 'c1']);
      expect(row(c, 'c9').other, cem);
    });

    test('a known conversation is not re-read for', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = await loaded(chat);
      final readsBefore = chat.calls.where((x) => x == 'conversations').length;

      chat.deliver(msg('c1', 40));
      await settle();

      expect(row(c, 'c1').lastMessage, 'new');
      expect(
        chat.calls.where((x) => x == 'conversations').length,
        readsBefore,
        reason: 'every message costs a full re-read',
      );
    });

    test(
      'a deletion event re-reads the list: it does not hold the message '
      'the deletion replaced, so it cannot compute the new preview itself',
      () async {
        final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
        await loaded(chat);
        final readsBefore = chat.calls
            .where((x) => x == 'conversations')
            .length;

        // The server now shows the conversation's preview one message back,
        // or as a placeholder -- whichever it settled on.
        chat.conversationsResult = Ok([
          conv('c1', 30).withPreview(
            Message(
              id: 'del-1',
              conversationId: 'c1',
              senderId: 'u2',
              body: '',
              createdAt: at(31),
              deletion: MessageDeletion.placeholder,
            ),
          ),
        ]);
        chat.deliver(
          Message(
            id: 'del-1',
            conversationId: 'c1',
            senderId: 'u2',
            body: '',
            createdAt: at(31),
            deletion: MessageDeletion.placeholder,
          ),
        );
        await settle();

        expect(
          chat.calls.where((x) => x == 'conversations').length,
          greaterThan(readsBefore),
          reason: 'a deletion event must trigger a re-read',
        );
      },
    );

    test('a message arriving during the first read is not lost', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)])
        ..holdList();
      final c = scope(chat);
      c.listen(conversationListProvider, (_, _) {});
      await settle();
      expect(chat.calls, contains('conversations'), reason: 'read in flight');

      // Arrives after the read's snapshot was taken, before it returned.
      chat.deliver(msg('c2', 40, body: 'meanwhile'));
      await settle();
      chat.releaseList();
      await c.read(conversationListProvider.future);
      await settle();

      expect(ids(c), ['c2', 'c1'], reason: 'the buffered message was dropped');
      expect(row(c, 'c2').lastMessage, 'meanwhile');
    });

    test(
      'an unknown conversation arriving during the first read appears',
      () async {
        final chat = ChatFake()
          ..conversationsResult = Ok([conv('c1', 30)])
          ..holdList();
        final c = scope(chat);
        c.listen(conversationListProvider, (_, _) {});
        await settle();
        expect(chat.calls, contains('conversations'), reason: 'read in flight');

        // Started after the read's snapshot: the read cannot contain it.
        chat.conversationsResult = Ok([
          conv('c9', 50, other: cem, text: 'hello there'),
          conv('c1', 30),
        ]);
        chat.deliver(msg('c9', 50, body: 'hello there', from: 'u3'));
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();

        expect(
          ids(c),
          contains('c9'),
          reason: 'a new conversation announced during the load was dropped',
        );
      },
    );

    test('a subscription that cannot be made still loads the list', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 30)])
        ..incomingAllResult = const Err(NetworkFailure('realtime down'));
      final c = scope(chat);
      c.listen(conversationListProvider, (_, _) {});
      await settle();

      final state = c.read(conversationListProvider);
      expect(
        state.hasError,
        isFalse,
        reason:
            'a live-update failure failed '
            'the whole list',
      );
      expect(state.isLoading, isFalse);
      expect(state.requireValue.single.id, 'c1');
    });

    test('the subscription ends with the list', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = await loaded(chat);
      c.dispose();
      await settle();
      expect(chat.canceledAllSubscriptions, greaterThan(0));
    });
  });

  group('start-up: the first read runs alongside the join', () {
    /// A signed-in scope whose list is watched, session settled first so the
    /// list is built once, for this member.
    Future<ProviderContainer> watching(ChatFake chat) async {
      final c = await settled(scope(chat));
      c.listen(conversationListProvider, (_, _) {});
      return c;
    }

    int reads(ChatFake chat) =>
        chat.calls.where((x) => x == 'conversations').length;

    test('starts the join and the first read together: neither waits for '
        'the other to answer', () async {
      final chat = JoinChat()
        ..conversationsResult = Ok([conv('c1', 30)])
        ..holdJoin()
        ..holdList();
      final c = await watching(chat);
      await settle();

      expect(chat.calls, contains('incomingAll'));
      expect(
        chat.calls,
        contains('conversations'),
        reason: 'the read waited for the join to be confirmed',
      );
      expect(c.read(conversationListProvider).isLoading, isTrue);

      // The read answers first; the join is still being set up.
      chat.releaseList();
      await settle();
      expect(ids(c), ['c1'], reason: 'the list waited for the join');

      chat.confirmJoin();
      await settle();
      expect(chat.listening, isTrue, reason: 'never listened once joined');
      chat.deliver(msg('c1', 40, body: 'live'));
      await settle();
      expect(row(c, 'c1').lastMessage, 'live');
    });

    test('a join that never completes still gives a list, not a wait and '
        'not an error', () async {
      final chat = JoinChat()
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)])
        ..holdJoin();
      final c = await watching(chat);
      final list = await c
          .read(conversationListProvider.future)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('the list waited for a join that never came'),
          );
      await settle();

      expect([for (final x in list) x.id], ['c1', 'c2']);
      final state = c.read(conversationListProvider);
      expect(state.isLoading, isFalse);
      expect(state.hasError, isFalse);
      expect(chat.joins, 0, reason: 'the join was never confirmed');
    });

    test('a list gone before its join completes leaves no subscription '
        'behind', () async {
      final chat = JoinChat()
        ..conversationsResult = Ok([conv('c1', 30)])
        ..holdJoin();
      final c = await watching(chat);
      await c.read(conversationListProvider.future);
      c.dispose();
      await settle();

      chat.confirmJoin();
      await settle();
      expect(chat.listening, isFalse, reason: 'a dead list still listens');
      expect(chat.listens, chat.cancels);
    });

    test(
      'rebuilt while the first join is still out: the replaced '
      'build\'s subscription ends, one stays live, an insert counted once',
      () async {
        final chat = JoinChat(self: 'u1')
          ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)])
          ..holdJoin();
        final c = await watching(chat);
        await c.read(conversationListProvider.future);
        await settle();

        // Rebuilt, as on an account change: a second join starts, and the
        // first one's list is gone before its join completes.
        c.invalidate(conversationListProvider);
        await c.read(conversationListProvider.future);
        await settle();
        expect(chat.calls.where((x) => x == 'incomingAll'), hasLength(2));
        chat.confirmJoin();
        await settle();
        chat.deliver(msg('c2', 40, body: 'meanwhile'));
        await settle();

        expect(
          chat.listens - chat.cancels,
          1,
          reason:
              'live subscriptions: the replaced build\'s join still listens, '
              'a Realtime channel nothing owns',
        );
        expect(ids(c), ['c2', 'c1']);
        expect(row(c, 'c2').unread, 1, reason: 'applied once per subscription');
      },
    );

    group('an insert is shown exactly once, whenever it arrives:', () {
      // self: the fake is the database too -- an insert is a row, and any
      // read after it includes it (preview and unread count).
      JoinChat world() => JoinChat(self: 'u1')
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)])
        ..holdJoin()
        ..holdList();

      void once(ProviderContainer c) {
        expect(ids(c), ['c2', 'c1'], reason: 'moved to the top, listed once');
        expect(row(c, 'c2').lastMessage, 'meanwhile');
        expect(row(c, 'c2').lastMessageAt, at(40));
        expect(row(c, 'c2').unread, 1, reason: 'lost (0) or applied twice (2)');
        expect(row(c, 'c1').unread, 0);
      }

      test('(b) joined, before the list listens, read still out', () async {
        final chat = world();
        final c = await watching(chat);
        await settle();
        expect(reads(chat), 1, reason: 'read in flight');
        expect(chat.listening, isFalse);

        // The server sends it the instant the join is confirmed: it is in
        // the stream before anyone could have listened.
        chat.confirmJoin(atJoin: [msg('c2', 40, body: 'meanwhile')]);
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();

        once(c);
      });

      test('(c) listening, before the first read answers', () async {
        final chat = world();
        final c = await watching(chat);
        await settle();
        chat.confirmJoin();
        await settle();
        expect(chat.listening, isTrue, reason: 'listens once joined');
        expect(c.read(conversationListProvider).isLoading, isTrue);

        chat.deliver(msg('c2', 40, body: 'meanwhile'));
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();

        once(c);
      });

      test('(c) the read already holds it: counted once, not again', () async {
        // The read ran after the insert: its preview and count include it.
        final m = msg('c2', 40, body: 'meanwhile');
        final chat = JoinChat()
          ..conversationsResult = Ok([
            conv('c2', 40, text: 'meanwhile').withPreview(m, counts: true),
            conv('c1', 30),
          ])
          ..holdJoin()
          ..holdList();
        final c = await watching(chat);
        await settle();
        chat.confirmJoin();
        await settle();
        chat.deliver(m);
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();

        expect(ids(c), ['c2', 'c1']);
        expect(
          row(c, 'c2').unread,
          1,
          reason: 'the same message counted twice',
        );
      });

      test('(d) after the first read has answered', () async {
        final chat = world();
        final c = await watching(chat);
        await settle();
        chat.confirmJoin();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();

        chat.deliver(msg('c2', 40, body: 'meanwhile'));
        await settle();

        once(c);
      });

      test('(d) the join confirmed only after the first read answered: '
          'what the server sends then still arrives', () async {
        final chat = world();
        final c = await watching(chat);
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();

        chat.confirmJoin(atJoin: [msg('c2', 40, body: 'meanwhile')]);
        await settle();

        once(c);
      });
    });

    group('a conversation not in the list yet is re-read for:', () {
      JoinChat world() => JoinChat()
        ..conversationsResult = Ok([conv('c1', 30)])
        ..holdJoin()
        ..holdList();

      /// Someone started a conversation after the read's snapshot.
      void newChatOnServer(JoinChat chat) => chat.conversationsResult = Ok([
        conv('c9', 50, other: cem, text: 'hello there'),
        conv('c1', 30),
      ]);

      final hello = msg('c9', 50, body: 'hello there', from: 'u3');

      test('(b) sent at the join, before the list listens', () async {
        final chat = world();
        final c = await watching(chat);
        await settle();
        newChatOnServer(chat);
        chat.confirmJoin(atJoin: [hello]);
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();
        await settle();

        expect(ids(c), ['c9', 'c1'], reason: 'the new conversation was lost');
        expect(row(c, 'c9').other, cem);
        expect(reads(chat), greaterThan(1), reason: 'no quiet re-read');
      });

      test('(c) while the first read is out', () async {
        final chat = world();
        final c = await watching(chat);
        await settle();
        chat.confirmJoin();
        await settle();
        newChatOnServer(chat);
        chat.deliver(hello);
        await settle();
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await settle();
        await settle();

        expect(ids(c), ['c9', 'c1'], reason: 'the new conversation was lost');
        expect(reads(chat), greaterThan(1), reason: 'no quiet re-read');
      });
    });
  });

  group('reloadQuietly and refresh', () {
    test('reloadQuietly picks up the new list without loading', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = scope(chat);
      final seen = <AsyncValue<List<Conversation>>>[];
      c.listen(conversationListProvider, (_, next) => seen.add(next));
      await c.read(conversationListProvider.future);
      await settle();
      seen.clear();

      chat.conversationsResult = Ok([conv('c2', 40), conv('c1', 30)]);
      await c.read(conversationListProvider.notifier).reloadQuietly();
      await settle();

      expect(ids(c), ['c2', 'c1']);
      expect(seen.where((s) => s.isLoading), isEmpty, reason: 'it spun');
    });

    test('reloadQuietly keeps the current list on failure', () async {
      final chat = ChatFake()..conversationsResult = Ok([conv('c1', 30)]);
      final c = scope(chat);
      final seen = <AsyncValue<List<Conversation>>>[];
      c.listen(conversationListProvider, (_, next) => seen.add(next));
      await c.read(conversationListProvider.future);
      await settle();
      seen.clear();

      chat.conversationsResult = const Err(NetworkFailure('offline'));
      await c.read(conversationListProvider.notifier).reloadQuietly();
      await settle();

      final state = c.read(conversationListProvider);
      expect(
        state.hasError,
        isFalse,
        reason: 'a quiet reload surfaced an error',
      );
      expect(ids(c), ['c1']);
      expect(seen.where((s) => s.isLoading), isEmpty, reason: 'it spun');
      expect(seen.where((s) => s.hasError), isEmpty);
    });

    test('refresh shows loading and reports a failure', () async {
      final chat = ChatFake(latency: const Duration(milliseconds: 5))
        ..conversationsResult = Ok([conv('c1', 30)]);
      final c = scope(chat);
      final seen = <AsyncValue<List<Conversation>>>[];
      c.listen(conversationListProvider, (_, next) => seen.add(next));
      await c.read(conversationListProvider.future);
      await settle();
      seen.clear();

      chat.conversationsResult = const Err(NetworkFailure('offline'));
      await c.read(conversationListProvider.notifier).refresh();
      await settle();

      expect(seen.where((s) => s.isLoading), isNotEmpty);
      final state = c.read(conversationListProvider);
      expect(state.hasError, isTrue);
      expect((state.error! as Failure).message, 'offline');
    });
  });

  group('conversation tile', () {
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

    Finder inKey(String key, String text) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.text(text),
      matchRoot: true,
    );

    String hhmm(DateTime t) {
      final l = t.toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(l.hour)}:${two(l.minute)}';
    }

    testWidgets('own message reads "You:", theirs does not', (tester) async {
      final today = DateTime.now().toUtc();
      final chat = ChatFake()
        ..conversationsResult = Ok([
          Conversation(
            id: 'c1',
            other: bob,
            lastMessage: 'on my way',
            lastMessageAt: today,
            lastSenderId: me.userId,
          ),
          Conversation(
            id: 'c2',
            other: cem,
            lastMessage: 'see you',
            lastMessageAt: today,
            lastSenderId: cem.userId,
          ),
        ]);
      await pump(tester, chat);

      expect(inKey('preview-c1', 'You: on my way'), findsOneWidget);
      expect(inKey('preview-c2', 'see you'), findsOneWidget);
      expect(find.textContaining('You: see you'), findsNothing);
    });

    testWidgets('the time of the last message is shown', (tester) async {
      final today = DateTime.now().toUtc();
      final chat = ChatFake()
        ..conversationsResult = Ok([
          Conversation(
            id: 'c1',
            other: bob,
            lastMessage: 'hi',
            lastMessageAt: today,
            lastSenderId: bob.userId,
          ),
          Conversation(
            id: 'c2',
            other: cem,
            lastMessage: 'old news',
            lastMessageAt: DateTime.utc(2024, 3, 7, 12),
            lastSenderId: cem.userId,
          ),
        ]);
      await pump(tester, chat);

      expect(inKey('preview-time-c1', hhmm(today)), findsOneWidget);
      expect(inKey('preview-time-c2', '07.03.24'), findsOneWidget);
    });

    testWidgets('no message: says so and shows no time', (tester) async {
      final chat = ChatFake()
        ..conversationsResult = const Ok([Conversation(id: 'c1', other: bob)]);
      await pump(tester, chat);

      expect(find.text('No messages yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-time-c1')), findsNothing);
      expect(find.textContaining('You:'), findsNothing);
    });

    testWidgets('a live message updates the tile', (tester) async {
      final chat = ChatFake()
        ..conversationsResult = const Ok([Conversation(id: 'c1', other: bob)]);
      await pump(tester, chat);
      expect(find.text('No messages yet'), findsOneWidget);

      chat.deliver(
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: me.userId,
          body: 'first!',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No messages yet'), findsNothing);
      expect(inKey('preview-c1', 'You: first!'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-time-c1')), findsOneWidget);
    });

    testWidgets('returning from a chat re-reads the list without a spinner', (
      tester,
    ) async {
      // Realtime is down, so only the quiet re-read can bring the list up to
      // date — the owner-reported "old preview after returning" case.
      final chat = ChatFake(latency: const Duration(milliseconds: 5))
        ..incomingAllResult = const Err(NetworkFailure('realtime down'))
        ..conversationsResult = const Ok([Conversation(id: 'c1', other: bob)]);
      await pump(tester, chat);

      await tester.tap(find.byKey(const ValueKey('conversation-c1')));
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);

      chat.conversationsResult = Ok([
        Conversation(
          id: 'c1',
          other: bob,
          lastMessage: 'sent while inside',
          lastMessageAt: DateTime.now().toUtc(),
          lastSenderId: me.userId,
        ),
      ]);
      final readsBefore = chat.calls.where((x) => x == 'conversations').length;
      await tester.pageBack();

      // Every frame on the way back: never a spinner in place of the list.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 5));
        expect(sisWait, findsNothing);
      }
      await tester.pumpAndSettle();

      expect(
        chat.calls.where((x) => x == 'conversations').length,
        greaterThan(readsBefore),
      );
      expect(inKey('preview-c1', 'You: sent while inside'), findsOneWidget);
    });
  });
}

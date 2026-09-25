// The conversation list kept live: written from the contract of
// ConversationListController and the list tile, against ChatFake — a
// subscription that is not confirmed until the test says so, a read that can
// be held open, and Realtime that delivers only to a live listener.

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
    test('subscribes before its first read', () async {
      final chat = ChatFake()
        ..conversationsResult = Ok([conv('c1', 0)])
        ..holdAllSubscription();
      final c = scope(chat);
      c.listen(conversationListProvider, (_, _) {});
      await settle();

      expect(chat.calls, contains('incomingAll'));
      expect(
        chat.calls,
        isNot(contains('conversations')),
        reason:
            'read before the subscription was confirmed: a message sent '
            'in between would be missed by both',
      );

      chat.confirmAllSubscription();
      await c.read(conversationListProvider.future);
      expect(
        chat.calls.indexOf('incomingAll'),
        lessThan(chat.calls.indexOf('conversations')),
      );
    });

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

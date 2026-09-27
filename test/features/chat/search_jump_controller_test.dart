// MessagesController.jumpToAround / returnToLive and ChatSearchController.select,
// from their contracts:
// - jumpToAround(anchor): the shown messages become the window around
//   [anchor] (oldest first, anchor included); on failure the Err carries the
//   repository's reason and the shown messages stay as they were.
// - returnToLive(): back to the live, newest window; a no-op when nothing
//   was jumped.
// - select(id): makes the hit with [id] current when it is among the hits;
//   a no-op otherwise.
// Against ChatFake, whose messages() answers the newest 500 like the real
// read, so "older than what is loaded" is real here.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

final _t0 = DateTime.utc(2026, 1, 1);

/// [n] messages in [conversation], one a minute, oldest first; the body of
/// every tenth says "needle".
List<Message> _history(String conversation, int n) => [
  for (var i = 0; i < n; i++)
    Message(
      id: '$conversation-$i',
      conversationId: conversation,
      senderId: i.isEven ? 'me' : 'bob',
      body: i % 10 == 0 ? 'needle $i' : 'hay $i',
      createdAt: _t0.add(Duration(minutes: i)),
    ),
];

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  MessagesController messages() => c.read(messagesProvider.notifier);
  int reads(String id) => chat.calls.where((x) => x == 'messages:$id').length;

  setUp(() async {
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    chat.history['c1'] = _history('c1', 600);
    chat.history['c2'] = _history('c2', 20);
    c = ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(chat)],
    );
    c.listen(messagesProvider, (_, _) {});
    c.listen(chatSearchProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
  });

  group('jumpToAround', () {
    test('fixture: only the newest 500 are loaded', () {
      expect(shown(), hasLength(500));
      expect(shown().first, 'c1-100');
      expect(shown().last, 'c1-599');
    });

    test('an anchor older than the loaded window: shows the window around '
        'it, oldest first, anchor included', () async {
      final anchor = chat.history['c1']![30];
      expect(shown(), isNot(contains(anchor.id)), reason: 'fixture');

      final r = await messages().jumpToAround(anchor);
      expect(r, isA<Ok<void>>());
      final ids = shown();
      expect(ids, contains(anchor.id));
      expect(
        ids,
        aroundRows(chat.history['c1']!, anchor).map((m) => m.id),
        reason: 'exactly the window the repository answered, in its order',
      );
      expect(chat.calls, contains('around:c1:${anchor.id}'));
    });

    test('a failed load returns the reason and keeps what was shown', () async {
      final before = shown();
      const offline = NetworkFailure('offline');
      chat.messagesAroundResult = const Err(offline);

      final r = await messages().jumpToAround(chat.history['c1']![30]);
      expect(r, isA<Err<void>>());
      expect((r as Err<void>).failure, same(offline));
      expect(shown(), before);
      expect(c.read(messagesProvider).hasError, isFalse);
    });

    test('an answer for a conversation already left is not shown in the '
        'next one', () async {
      final anchor = chat.history['c1']![30];
      final pending = messages().jumpToAround(anchor);
      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        shown().every((id) => id.startsWith('c2-')),
        isTrue,
        reason: "c1's window must not land in c2",
      );
    });
  });

  group('returnToLive', () {
    test('after a jump: back to the newest 500, including what arrived '
        'meanwhile', () async {
      await messages().jumpToAround(chat.history['c1']![30]);
      final late = Message(
        id: 'c1-new',
        conversationId: 'c1',
        senderId: 'bob',
        body: 'arrived while jumped',
        createdAt: _t0.add(const Duration(days: 2)),
      );
      chat.deliver(late);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      messages().returnToLive();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final ids = shown();
      expect(ids.last, 'c1-new', reason: 'the live newest message');
      expect(ids, hasLength(500));
      expect(ids, isNot(contains('c1-30')), reason: 'the jumped window left');
    });

    test('with nothing jumped: a no-op, no reload', () async {
      final before = shown();
      final asked = reads('c1');
      messages().returnToLive();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(shown(), before);
      expect(reads('c1'), asked);
    });
  });

  group('ChatSearchController.select', () {
    test('makes a hit current; an unknown id changes nothing', () async {
      final search = c.read(chatSearchProvider.notifier);
      await search.search('needle');
      final hits = c.read(chatSearchProvider).hits;
      expect(hits.length, greaterThan(3), reason: 'fixture');

      search.select(hits[3].id);
      expect(c.read(chatSearchProvider).index, 3);
      expect(c.read(chatSearchProvider).current!.id, hits[3].id);

      search.select('nope');
      expect(c.read(chatSearchProvider).index, 3);
      expect(c.read(chatSearchProvider).query, 'needle');
      expect(c.read(chatSearchProvider).hits, hits);
    });
  });
}

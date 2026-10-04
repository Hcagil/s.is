import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

import '../../support/fakes.dart';

void main() {
  group('ChatSearchController', () {
    late ChatFake chat;
    late ProviderContainer container;
    late ProviderSubscription<ChatSearchState> subscription;

    setUp(() {
      chat = ChatFake();
      // Prepare history for conversation c1
      final m1 = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 's1',
        body: 'Hello world',
        createdAt: DateTime(2023, 1, 1),
      );
      final m2 = Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 's2',
        body: 'Another hello',
        createdAt: DateTime(2023, 1, 2),
      );
      final m3 = Message(
        id: 'm3',
        conversationId: 'c1',
        senderId: 's3',
        body: 'Hello again',
        createdAt: DateTime(2023, 1, 3),
      );
      final m4 = Message(
        id: 'm4',
        conversationId: 'c1',
        senderId: 's4',
        body: 'Goodbye',
        createdAt: DateTime(2023, 1, 4),
      );
      chat.history['c1'] = [m1, m2, m3, m4];

      // Prepare history for conversation c2
      final m5 = Message(
        id: 'm5',
        conversationId: 'c2',
        senderId: 's5',
        body: 'Hello c2',
        createdAt: DateTime(2023, 1, 5),
      );
      chat.history['c2'] = [m5];

      container = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(chat)],
      );
      subscription = container.listen(chatSearchProvider, (_, _) {});
    });

    tearDown(() {
      subscription.close();
      container.dispose();
    });

    test(
      'search with no open conversation returns DeniedFailure and no repo call',
      () async {
        final result = await container
            .read(chatSearchProvider.notifier)
            .search('hello');
        expect(
          result,
          isA<Err<void>>().having(
            (e) => e.failure,
            'failure',
            isA<DeniedFailure>(),
          ),
        );
        expect(chat.searches.isEmpty, true);
      },
    );

    test(
      'search with open conversation records query and conversationId',
      () async {
        container.read(openConversationProvider.notifier).open('c1');
        final result = await container
            .read(chatSearchProvider.notifier)
            .search('hello');
        expect(result, isA<Ok<void>>());
        expect(chat.searches.length, 1);
        expect(chat.searches.single.query, 'hello');
        expect(chat.searches.single.conversationId, 'c1');

        final state = container.read(chatSearchProvider);
        expect(state.query, 'hello');
        expect(state.hits.length, 3);
        expect(state.index, 0);
        expect(state.current, state.hits[0]); // newest first
        // Verify order: newest first
        expect(state.hits[0].id, 'm3');
        expect(state.hits[1].id, 'm2');
        expect(state.hits[2].id, 'm1');
      },
    );

    test(
      'search with no matching hits sets index to -1 and current to null',
      () async {
        container.read(openConversationProvider.notifier).open('c1');
        final result = await container
            .read(chatSearchProvider.notifier)
            .search('xyz');
        expect(result, isA<Ok<void>>());
        final state = container.read(chatSearchProvider);
        expect(state.hits.isEmpty, true);
        expect(state.index, -1);
        expect(state.current, null);
      },
    );

    test('fewer than three letters or digits: no request, no hits', () async {
      container.read(openConversationProvider.notifier).open('c1');
      container.listen(messagesProvider, (_, _) {});
      await container.read(messagesProvider.future);
      final notifier = container.read(chatSearchProvider.notifier);
      await notifier.search('hello');
      expect(container.read(chatSearchProvider).hits, hasLength(3));
      final asked = chat.searches.length;
      for (final q in [
        'h',
        'he',
        ' he ',
        'he\n',
        '...',
        '!!!',
        '😂😂😂',
        'h..',
      ]) {
        final result = await notifier.search(q);
        expect(result, isA<Ok<void>>(), reason: '"$q" is not a failure');
        expect(chat.searches.length, asked, reason: '"$q" asks nothing');
        final state = container.read(chatSearchProvider);
        expect(state.hits, isEmpty, reason: '"$q" shows no hits');
        expect(state.current, isNull, reason: '"$q"');
      }
      // Three do: 'hel' is searchable. c1's messages are loaded, so it
      // answers from them and asks nothing; one with no local hit asks.
      await notifier.search('hel');
      expect(container.read(chatSearchProvider).hits, hasLength(3));
      expect(chat.searches.length, asked, reason: 'answered from the phone');
      await notifier.search('goo');
      expect(container.read(chatSearchProvider).hits, hasLength(1));
      await notifier.search('xyz');
      expect(chat.searches.length, asked + 1, reason: 'no local hit: asks');
    });

    test(
      'next() and previous() navigate correctly and clamp at ends',
      () async {
        container.read(openConversationProvider.notifier).open('c1');
        await container.read(chatSearchProvider.notifier).search('hello');
        final notifier = container.read(chatSearchProvider.notifier);

        // Initial state
        var state = container.read(chatSearchProvider);
        expect(state.index, 0);
        expect(state.current!.id, 'm3');

        // next()
        notifier.next();
        state = container.read(chatSearchProvider);
        expect(state.index, 1);
        expect(state.current!.id, 'm2');

        // next()
        notifier.next();
        state = container.read(chatSearchProvider);
        expect(state.index, 2);
        expect(state.current!.id, 'm1');

        // next() at last hit stays
        notifier.next();
        state = container.read(chatSearchProvider);
        expect(state.index, 2);
        expect(state.current!.id, 'm1');

        // previous()
        notifier.previous();
        state = container.read(chatSearchProvider);
        expect(state.index, 1);
        expect(state.current!.id, 'm2');

        // previous()
        notifier.previous();
        state = container.read(chatSearchProvider);
        expect(state.index, 0);
        expect(state.current!.id, 'm3');

        // previous() at first hit stays
        notifier.previous();
        state = container.read(chatSearchProvider);
        expect(state.index, 0);
        expect(state.current!.id, 'm3');
      },
    );

    test('next() and previous() are no-ops when there are no hits', () async {
      container.read(openConversationProvider.notifier).open('c1');
      await container.read(chatSearchProvider.notifier).search('xyz');
      final notifier = container.read(chatSearchProvider.notifier);
      final stateBefore = container.read(chatSearchProvider);
      expect(stateBefore.index, -1);
      expect(stateBefore.current, null);

      notifier.next();
      var state = container.read(chatSearchProvider);
      expect(state.index, -1);
      expect(state.current, null);

      notifier.previous();
      state = container.read(chatSearchProvider);
      expect(state.index, -1);
      expect(state.current, null);
    });

    test('a failed search shows the new query\'s own truth, never the '
        'previous query\'s hits, and returns the failure', () async {
      container.read(openConversationProvider.notifier).open('c1');
      var result = await container
          .read(chatSearchProvider.notifier)
          .search('hello');
      expect(result, isA<Ok<void>>());
      expect(container.read(chatSearchProvider).hits, isNotEmpty);

      chat.searchResult = Err(NetworkFailure('down'));
      // No local hit for this one (and nothing on the server either way):
      // the server has to be asked, and fails.
      result = await container
          .read(chatSearchProvider.notifier)
          .search('farewell');
      expect(
        result,
        isA<Err<void>>().having(
          (e) => e.failure,
          'failure',
          isA<NetworkFailure>(),
        ),
      );

      final state = container.read(chatSearchProvider);
      expect(state.query, 'farewell');
      expect(state.hits, isEmpty, reason: 'hello\'s hits must not linger');
      expect(state.index, -1);
      expect(state.current, isNull);
      expect(
        state.serverAnswered,
        isFalse,
        reason: 'a failure is not an answer: never "No results"',
      );
    });

    test('close() resets the state', () async {
      container.read(openConversationProvider.notifier).open('c1');
      await container.read(chatSearchProvider.notifier).search('hello');
      final stateBeforeClose = container.read(chatSearchProvider);
      expect(stateBeforeClose.query.isNotEmpty, true);
      expect(stateBeforeClose.hits.isNotEmpty, true);
      expect(stateBeforeClose.index, isNot(-1));

      container.read(chatSearchProvider.notifier).close();
      final stateAfterClose = container.read(chatSearchProvider);
      expect(stateAfterClose.query, '');
      expect(stateAfterClose.hits.isEmpty, true);
      expect(stateAfterClose.index, -1);
      expect(stateAfterClose.current, null);
    });

    test('opening a new conversation resets the state', () async {
      // Search in c1
      container.read(openConversationProvider.notifier).open('c1');
      await container.read(chatSearchProvider.notifier).search('hello');
      final stateC1 = container.read(chatSearchProvider);
      expect(stateC1.query.isNotEmpty, true);
      expect(stateC1.hits.isNotEmpty, true);

      // Open c2
      container.read(openConversationProvider.notifier).open('c2');
      final stateAfterOpenC2 = container.read(chatSearchProvider);
      expect(stateAfterOpenC2.query, '');
      expect(stateAfterOpenC2.hits.isEmpty, true);
      expect(stateAfterOpenC2.index, -1);

      // Search in c2
      await container.read(chatSearchProvider.notifier).search('hello');
      final stateC2 = container.read(chatSearchProvider);
      expect(stateC2.query, 'hello');
      expect(stateC2.hits.length, 1);
      expect(stateC2.hits.first.id, 'm5');
      expect(stateC2.index, 0);
    });

    test('closing the conversation resets the state', () async {
      container.read(openConversationProvider.notifier).open('c1');
      await container.read(chatSearchProvider.notifier).search('hello');
      final stateBeforeClose = container.read(chatSearchProvider);
      expect(stateBeforeClose.query.isNotEmpty, true);
      expect(stateBeforeClose.hits.isNotEmpty, true);

      // Close conversation
      container.read(openConversationProvider.notifier).close();
      final stateAfterClose = container.read(chatSearchProvider);
      expect(stateAfterClose.query, '');
      expect(stateAfterClose.hits.isEmpty, true);
      expect(stateAfterClose.index, -1);

      // Search again should fail with DeniedFailure
      final result = await container
          .read(chatSearchProvider.notifier)
          .search('hello');
      expect(
        result,
        isA<Err<void>>().having(
          (e) => e.failure,
          'failure',
          isA<DeniedFailure>(),
        ),
      );
    });

    test('a repository failure is returned as that very failure', () async {
      container.read(openConversationProvider.notifier).open('c1');
      const down = NetworkFailure('down');
      chat.searchResult = const Err(down);
      final result = await container
          .read(chatSearchProvider.notifier)
          .search('hello');
      expect(
        result,
        isA<Err<void>>().having((e) => e.failure, 'failure', same(down)),
      );
      final state = container.read(chatSearchProvider);
      expect(state.query, 'hello', reason: 'the query typed stays');
      expect(state.hits, isEmpty, reason: 'nothing loaded, nothing answered');
      expect(state.index, -1);
      expect(state.serverAnswered, isFalse);
    });

    test('a new search starts again at its newest hit', () async {
      container.read(openConversationProvider.notifier).open('c1');
      final notifier = container.read(chatSearchProvider.notifier);
      await notifier.search('hello');
      notifier.next();
      notifier.next();
      expect(container.read(chatSearchProvider).index, 2);

      await notifier.search('hello again');
      final state = container.read(chatSearchProvider);
      expect(state.query, 'hello again');
      expect(state.hits.map((m) => m.id), ['m3']);
      expect(state.index, 0);
      expect(state.current!.id, 'm3');

      notifier.next();
      expect(
        container.read(chatSearchProvider).index,
        0,
        reason: 'one hit: next() clamps, it does not run off the end',
      );
      notifier.previous();
      expect(container.read(chatSearchProvider).index, 0);
    });

    test('an answer for the conversation just left is not shown in the next '
        'one', () async {
      container.read(openConversationProvider.notifier).open('c1');
      final held = chat.holdSearch();
      final pending = container
          .read(chatSearchProvider.notifier)
          .search('hello');
      await Future<void>.delayed(Duration.zero);
      container.read(openConversationProvider.notifier).open('c2');
      // c2's search is already showing (rebuilt, empty) when c1's answer lands.
      expect(container.read(chatSearchProvider).query, '');
      held.complete();
      await pending;

      final state = container.read(chatSearchProvider);
      expect(
        state.hits.where((m) => m.conversationId == 'c1'),
        isEmpty,
        reason: 'c1\'s hits must never appear while c2 is open',
      );
      expect(state.index, -1);
      expect(state.query, '');
    });
  });

  // v0.18: in-chat search answers from the messages already loaded on the
  // phone (the open conversation's newest page) and asks the server only when
  // there is no local hit, or when ↑ older is pressed on the oldest local hit
  // before the server has answered. ChatFake's messages() answers the newest
  // page like the real read, so "not loaded" is real here.
  group('instant from the phone', () {
    final t0 = DateTime.utc(2026, 1, 1);
    late ChatFake chat;
    late ProviderContainer c;

    /// [n] messages, one a minute, oldest first; [bodies] overrides by index.
    List<Message> history(String id, int n, Map<int, String> bodies) => [
      for (var i = 0; i < n; i++)
        Message(
          id: '$id-$i',
          conversationId: id,
          senderId: i.isEven ? 'me' : 'bob',
          body: bodies[i] ?? 'hay $i',
          createdAt: t0.add(Duration(minutes: i)),
        ),
    ];

    ChatSearchState state() => c.read(chatSearchProvider);
    ChatSearchController search() => c.read(chatSearchProvider.notifier);
    List<String> ids() => state().hits.map((m) => m.id).toList();
    List<String> asked() => chat.searches.map((s) => s.query).toList();

    Future<void> openLoaded(String id) async {
      c.read(openConversationProvider.notifier).open(id);
      await c.read(messagesProvider.future);
      chat.confirmSubscription();
    }

    /// Lets every pending fake call (2 ms each) finish.
    Future<void> drain() =>
        Future<void>.delayed(const Duration(milliseconds: 30));

    setUp(() async {
      chat = ChatFake(latency: const Duration(milliseconds: 2));
      // 600 in c1: 0..549 are older than the newest page (50) and never loaded.
      chat.history['c1'] = history('c1', 600, {
        20: 'Apple pie',
        40: 'an apple crumble',
        551: 'APPLE juice',
        560: 'apple again',
        590: 'green apple',
        595: 'the last apple',
      });
      chat.history['c2'] = history('c2', 3, {1: 'apple in c2'});
      c = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(chat)],
      );
      c.listen(messagesProvider, (_, _) {});
      c.listen(chatSearchProvider, (_, _) {});
      await openLoaded('c1');
      expect(c.read(messagesProvider).requireValue, hasLength(messagePageSize));
    });

    tearDown(() => c.dispose());

    test('local hits show at once, before any round trip, newest first; the '
        'server is not asked', () async {
      final pending = search().search('apple');
      // Not awaited: the local answer is there synchronously.
      expect(ids(), ['c1-595', 'c1-590', 'c1-560', 'c1-551']);
      expect(state().query, 'apple');
      expect(state().index, 0);
      expect(state().current!.id, 'c1-595');
      expect(state().serverAnswered, isFalse, reason: 'local only: "+"');
      expect(await pending, isA<Ok<void>>());
      await drain();
      expect(asked(), isEmpty, reason: 'there were local hits');
      expect(ids(), ['c1-595', 'c1-590', 'c1-560', 'c1-551']);
    });

    test('local matching folds like the server: İ, I, ı and i are one letter, '
        'case never matters', () async {
      chat.history['c3'] = history('c3', 4, {
        0: 'İSTANBUL once',
        1: 'Istanbul twice',
        2: 'ıstanbul thrice',
        3: 'unrelated',
      });
      await openLoaded('c3');
      for (final q in ['istanbul', 'İSTANBUL', 'ISTANBUL', 'ıstanbul']) {
        await search().search(q);
        expect(ids(), ['c3-2', 'c3-1', 'c3-0'], reason: q);
      }
      await drain();
      expect(asked(), isEmpty, reason: 'every fold matched locally');
    });

    test('deleted, vanished and empty (attachment-only) messages are never a '
        'local hit', () async {
      chat.history['c3'] = [
        Message(
          id: 'kept',
          conversationId: 'c3',
          senderId: 'bob',
          body: 'banana split',
          createdAt: t0,
        ),
        Message(
          id: 'placeholder',
          conversationId: 'c3',
          senderId: 'bob',
          body: 'banana gone',
          createdAt: t0.add(const Duration(minutes: 1)),
          deletion: MessageDeletion.placeholder,
        ),
        Message(
          id: 'vanished',
          conversationId: 'c3',
          senderId: 'bob',
          body: 'banana vanished',
          createdAt: t0.add(const Duration(minutes: 2)),
          deletion: MessageDeletion.vanished,
        ),
        Message(
          id: 'photo',
          conversationId: 'c3',
          senderId: 'bob',
          body: '',
          createdAt: t0.add(const Duration(minutes: 3)),
          attachmentPath: 'c3/banana.jpg',
        ),
      ];
      await openLoaded('c3');
      await search().search('banana');
      expect(ids(), ['kept']);
      await drain();
      expect(asked(), isEmpty);
    });

    test('no local hit: the server is asked for this chat and its answer '
        'shown, then it is never asked again for that query', () async {
      final result = await search().search('apple pie');
      expect(result, isA<Ok<void>>());
      expect(chat.searches.single.query, 'apple pie');
      expect(chat.searches.single.conversationId, 'c1');
      expect(ids(), ['c1-20']);
      expect(state().serverAnswered, isTrue);
      expect(state().index, 0);
      search().next();
      search().next();
      search().previous();
      await drain();
      expect(chat.searches, hasLength(1), reason: 'answered already');
      expect(state().index, 0);
    });

    test('no hit anywhere: empty, answered (so "No results")', () async {
      await search().search('zebra');
      expect(asked(), ['zebra']);
      expect(ids(), isEmpty);
      expect(state().index, -1);
      expect(state().serverAnswered, isTrue);
    });

    test('while the server is out, a no-local-hit search shows nothing and '
        'is not answered yet', () async {
      final held = chat.holdSearch();
      final pending = search().search('zebra');
      await drain();
      expect(state().query, 'zebra');
      expect(ids(), isEmpty);
      expect(state().serverAnswered, isFalse, reason: 'not "No results" yet');
      held.complete();
      await pending;
      expect(state().serverAnswered, isTrue);
    });

    test('↑ on the oldest local hit asks the server once, merges its older '
        'hits without duplicates, newest first, and moves onto the next '
        'older one', () async {
      await search().search('apple');
      search().next();
      search().next();
      search().next();
      expect(state().current!.id, 'c1-551', reason: 'oldest local hit');
      await drain();
      expect(asked(), isEmpty, reason: 'walking local hits asks nothing');

      search().next(); // past the oldest local hit
      await drain();
      expect(chat.searches.single.query, 'apple');
      expect(chat.searches.single.conversationId, 'c1');
      expect(ids(), [
        'c1-595',
        'c1-590',
        'c1-560',
        'c1-551',
        'c1-40',
        'c1-20',
      ], reason: 'local ∪ server, each message once, newest first');
      expect(state().serverAnswered, isTrue);
      expect(state().current!.id, 'c1-40', reason: 'the next older hit');

      search().next();
      expect(state().current!.id, 'c1-20');
      search().next();
      await drain();
      expect(state().current!.id, 'c1-20', reason: 'clamped at the oldest');
      for (var i = 0; i < 6; i++) {
        search().previous();
      }
      search().next();
      await drain();
      expect(chat.searches, hasLength(1), reason: 'never asked again');
      expect(state().index, 1);
    });

    test('↑ on the oldest local hit when the server has nothing older: stays '
        'there, answered, and does not ask again', () async {
      await search().search('green apple');
      expect(ids(), ['c1-590']);
      expect(state().serverAnswered, isFalse);
      search().next();
      await drain();
      expect(asked(), ['green apple']);
      expect(ids(), ['c1-590'], reason: 'the same message, once');
      expect(state().current!.id, 'c1-590');
      expect(state().serverAnswered, isTrue);
      search().next();
      await drain();
      expect(asked(), hasLength(1));
    });

    test('↑ before the oldest local hit, and ↓, never ask', () async {
      await search().search('apple');
      search().next();
      search().next();
      search().previous();
      search().previous();
      search().previous();
      await drain();
      expect(asked(), isEmpty);
    });

    test('only the loaded newest page is searched locally', () async {
      await search().search('crumble'); // 40: in history, not loaded
      expect(asked(), ['crumble'], reason: 'not on the phone: asks');
      expect(ids(), ['c1-40']);
    });

    test('a server answer for a query since replaced is dropped: the newer '
        'query\'s local hits stay', () async {
      final held = chat.holdSearch();
      final stale = search().search('crumble');
      await drain();
      expect(asked(), ['crumble']);
      await search().search('apple');
      final before = ids();
      expect(before, hasLength(4));
      held.complete();
      await stale;
      await drain();
      expect(state().query, 'apple');
      expect(ids(), before, reason: 'crumble\'s answer must not land here');
      expect(state().serverAnswered, isFalse, reason: 'apple not answered');
      expect(state().index, 0);
    });

    test(
      'an ↑ answer that arrives after the query changed is dropped',
      () async {
        await search().search('apple');
        for (var i = 0; i < 3; i++) {
          search().next();
        }
        final held = chat.holdSearch();
        search().next(); // asks the server for "apple"
        await drain();
        expect(asked(), ['apple']);
        await search().search('green apple');
        held.complete();
        await drain();
        expect(state().query, 'green apple');
        expect(ids(), ['c1-590'], reason: 'apple\'s older hits must not land');
        expect(state().serverAnswered, isFalse);
        expect(state().current!.id, 'c1-590');
      },
    );

    test(
      'answers arriving out of order: only the current query\'s counts',
      () async {
        final first = chat.holdSearch();
        final second = chat.holdSearch();
        final a = search().search('crumble');
        await drain();
        final b = search().search('pie');
        await drain();
        expect(asked(), ['crumble', 'pie']);
        second.complete();
        await b;
        expect(ids(), ['c1-20']);
        first.complete();
        await a;
        await drain();
        expect(state().query, 'pie');
        expect(ids(), ['c1-20'], reason: 'the older query\'s late answer');
      },
    );

    test('while the next chat\'s messages are still loading, the chat just '
        'left never answers for it', () async {
      await search().search('apple');
      expect(ids(), hasLength(4), reason: 'fixture: c1 answered locally');
      chat.holdMessages();
      c.read(openConversationProvider.notifier).open('c2');
      await drain();
      final pending = search().search('apple');
      expect(
        state().hits.where((m) => m.conversationId != 'c2'),
        isEmpty,
        reason: 'c1\'s loaded messages are not c2\'s',
      );
      chat.releaseMessages();
      await pending;
      await drain();
      expect(ids(), ['c2-1']);
    });

    test(
      'an answer for the same query from a chat since left is dropped',
      () async {
        final fromC1 = chat.holdSearch();
        final stale = search().search('crumble'); // c1-40: not loaded
        await drain();
        await openLoaded('c2');
        final fromC2 = chat.holdSearch();
        final current = search().search('crumble'); // nothing in c2
        await drain();
        expect(chat.searches.map((s) => s.conversationId), ['c1', 'c2']);
        fromC1.complete();
        await stale;
        await drain();
        expect(ids(), isEmpty, reason: 'c1\'s crumble is not c2\'s');
        expect(state().serverAnswered, isFalse, reason: 'c2 not answered');
        fromC2.complete();
        await current;
        expect(ids(), isEmpty);
        expect(state().serverAnswered, isTrue);
      },
    );

    test('an answer for a chat since left is dropped', () async {
      final held = chat.holdSearch();
      final stale = search().search('crumble');
      await drain();
      await openLoaded('c2');
      await search().search('apple');
      expect(ids(), ['c2-1']);
      held.complete();
      await stale;
      await drain();
      expect(ids(), ['c2-1']);
      expect(state().hits.where((m) => m.conversationId == 'c1'), isEmpty);
    });

    test('a failed ↑ answer keeps the local hits, the oldest current, and '
        'not answered', () async {
      await search().search('apple');
      for (var i = 0; i < 3; i++) {
        search().next();
      }
      chat.searchResult = const Err(NetworkFailure('down'));
      search().next();
      await drain();
      expect(asked(), ['apple']);
      expect(ids(), ['c1-595', 'c1-590', 'c1-560', 'c1-551']);
      expect(state().current!.id, 'c1-551');
      expect(state().serverAnswered, isFalse);
    });

    test('a failed no-local-hit search after a local one: the old hits go, '
        'nothing current, not answered', () async {
      await search().search('apple');
      expect(ids(), hasLength(4));
      chat.searchResult = const Err(NetworkFailure('down'));
      final r = await search().search('crumble');
      expect(r, isA<Err<void>>());
      expect(state().query, 'crumble');
      expect(ids(), isEmpty);
      expect(state().index, -1);
      expect(state().serverAnswered, isFalse);
    });
  });
}

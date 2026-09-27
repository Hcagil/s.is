import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/core/failure.dart';
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
      await notifier.search('hel');
      expect(chat.searches.length, asked + 1, reason: 'three characters do');
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

    test(
      'repository error leaves state unchanged and returns the failure',
      () async {
        container.read(openConversationProvider.notifier).open('c1');
        // First successful search
        var result = await container
            .read(chatSearchProvider.notifier)
            .search('hello');
        expect(result, isA<Ok<void>>());
        final stateAfterSuccess = container.read(chatSearchProvider);

        // Force repository error
        chat.searchResult = Err(NetworkFailure('down'));

        // Second search triggers error
        result = await container
            .read(chatSearchProvider.notifier)
            .search('hello');
        expect(
          result,
          isA<Err<void>>().having(
            (e) => e.failure,
            'failure',
            isA<NetworkFailure>(),
          ),
        );

        // State should be unchanged
        final stateAfterError = container.read(chatSearchProvider);
        expect(stateAfterError.query, stateAfterSuccess.query);
        expect(stateAfterError.hits, stateAfterSuccess.hits);
        expect(stateAfterError.index, stateAfterSuccess.index);
        expect(stateAfterError.current, stateAfterSuccess.current);
      },
    );

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
      expect(state.query, '', reason: 'nothing searched successfully yet');
      expect(state.hits, isEmpty);
      expect(state.index, -1);
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
}

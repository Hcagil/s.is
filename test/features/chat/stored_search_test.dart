// Seam: ChatSearchController / ChatListSearchController <-> REAL encrypted
// MessageStore <-> ChatFake (whose search RPC can be held). From the Private
// Chats step 1 Group B contract:
// - in-chat: in-memory hits at once, then stored hits merged; the RPC only
//   when the chat is not complete and nothing was found; next() never calls
//   the server once the chat is complete;
// - list: local hits, then the RPC unless every listed chat is complete;
//   merged by id, newest first;
// - 2-character queries find nothing; "istanbul" finds "İstanbul".

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

List<Message> _rows(
  int from,
  int to, {
  String conv = 'c1',
  Map<int, String> bodies = const {},
}) => [
  for (var i = from; i < to; i++)
    msg('$conv-$i', conv: conv, t: i, body: bodies[i] ?? 'row $i'),
];

class _Me extends CurrentUserId {
  @override
  String? build() => 'me';
}

void main() {
  late StoreHarness h;
  late DriftMessageStore real;
  late SpyStore store;
  late ChatFake chat;
  late ProviderContainer c;

  Future<void> settle([int ms = 300]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() async {
    h = await StoreHarness.create();
    real = h.open(owner: 'me', key: await h.newKey());
    // Before the temp dir goes: fire-and-forget writes may still be running.
    addTearDown(real.close);
    store = SpyStore(real);
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        messageStoreProvider.overrideWithValue(store),
        currentUserIdProvider.overrideWith(_Me.new),
        sendQueueStoreProvider.overrideWithValue(SendQueueStoreFake()),
      ],
    );
    c.listen(messagesProvider, (_, _) {});
    c.listen(chatSearchProvider, (_, _) {});
    c.listen(chatListSearchProvider, (_, _) {});
  });

  group('in-chat search', () {
    ChatSearchController search() => c.read(chatSearchProvider.notifier);
    List<String> hits() =>
        c.read(chatSearchProvider).hits.map((m) => m.id).toList();

    Future<void> open(String id) async {
      c.read(openConversationProvider.notifier).open(id);
      await c.read(messagesProvider.future);
      await settle();
    }

    test(
      'memory hits at once, then stored hits merged, no RPC when found',
      () async {
        final rows = _rows(
          0,
          120,
          bodies: {5: 'İstanbul trip', 90: 'istanbul again'},
        );
        chat.history['c1'] = rows;
        await real.reconcilePage('c1', rows, reachedStart: false);
        await open('c1'); // memory: c1-70..c1-119

        final pending = search().search('istanbul');
        expect(hits(), ['c1-90'], reason: 'memory hit, synchronously');
        await pending;
        await eventually(() => hits().length == 2, reason: 'stored hit merged');
        expect(hits(), ['c1-90', 'c1-5'], reason: 'newest first; İ folds to i');
        expect(chat.searches, isEmpty, reason: 'something was found');
      },
    );

    test(
      'nothing found and the chat is not complete: the RPC is asked',
      () async {
        final rows = _rows(0, 120, bodies: {2: 'zebra crossing'});
        chat.history['c1'] = rows;
        await open('c1'); // store only holds the newest page: c1-70..c1-119

        await search().search('zebra');
        await eventually(() => hits().isNotEmpty);
        expect(chat.searches, hasLength(1));
        expect(hits(), ['c1-2']);
      },
    );

    test('nothing found in a complete chat: the RPC is not asked', () async {
      final rows = _rows(0, 70);
      chat.history['c1'] = rows;
      await real.reconcilePage('c1', rows, reachedStart: true);
      await open('c1');

      await search().search('zebra');
      await settle();
      expect(chat.searches, isEmpty);
      expect(hits(), isEmpty);
    });

    test(
      'next() past the oldest hit never calls the server once complete',
      () async {
        final rows = _rows(0, 70, bodies: {3: 'needle old', 60: 'needle new'});
        chat.history['c1'] = rows;
        await real.reconcilePage('c1', rows, reachedStart: true);
        await open('c1');

        await search().search('needle');
        await eventually(() => hits().length == 2);
        search().next();
        search().next();
        search().next();
        await settle();
        expect(chat.searches, isEmpty);
        expect(hits(), ['c1-60', 'c1-3']);
      },
    );

    test(
      'control: next() past the oldest hit of a not-complete chat asks',
      () async {
        final rows = _rows(
          0,
          120,
          bodies: {3: 'needle old', 100: 'needle new'},
        );
        chat.history['c1'] = rows;
        await open('c1');

        await search().search('needle');
        expect(hits(), ['c1-100']);
        search().next();
        await eventually(() => chat.searches.isNotEmpty);
      },
    );

    test('a 2-character query finds nothing and asks nothing', () async {
      final rows = _rows(0, 20, bodies: {4: 'is it'});
      chat.history['c1'] = rows;
      await open('c1');

      await search().search('is');
      await settle();
      expect(hits(), isEmpty);
      expect(chat.searches, isEmpty);
    });
  });

  group('chat list search', () {
    ChatListSearchController search() =>
        c.read(chatListSearchProvider.notifier);
    List<String> results() =>
        c.read(chatListSearchProvider).results.map((m) => m.id).toList();

    Future<void> listChats() async {
      chat.conversationsResult = const Ok([
        Conversation(id: 'c1'),
        Conversation(id: 'c2'),
      ]);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      await settle();
    }

    test(
      'every listed chat complete: local hits only, no RPC; İstanbul',
      () async {
        await real.reconcilePage(
          'c1',
          _rows(0, 3, bodies: {1: 'İstanbul one'}),
          reachedStart: true,
        );
        await real.reconcilePage(
          'c2',
          _rows(0, 3, conv: 'c2', bodies: {2: 'to istanbul'}),
          reachedStart: true,
        );
        await listChats();

        search().search('istanbul');
        await settle(600);
        expect(results(), ['c2-2', 'c1-1']);
        expect(chat.searches, isEmpty);
      },
    );

    test('one chat not complete: local hits first, then the RPC, merged by '
        'id, newest first', () async {
      await real.reconcilePage(
        'c1',
        _rows(0, 3, bodies: {1: 'xabc one'}),
        reachedStart: true,
      );
      chat.history['c1'] = _rows(0, 3, bodies: {1: 'xabc one'});
      chat.history['c2'] = _rows(0, 80, conv: 'c2', bodies: {5: 'xabc two'});
      await listChats(); // c2 never stored as complete
      final held = chat.holdSearch();

      search().search('xabc');
      await eventually(() => chat.searches.isNotEmpty, reason: 'RPC asked');
      expect(results(), ['c1-1'], reason: 'local hits before the server');

      held.complete();
      await eventually(() => results().length == 2);
      expect(results(), ['c2-5', 'c1-1'], reason: 'c1-1 not duplicated');
    });

    test('a 2-character query finds nothing and asks nothing', () async {
      await real.reconcilePage(
        'c1',
        _rows(0, 3, bodies: {1: 'xa xa'}),
        reachedStart: true,
      );
      await listChats();
      search().search('xa');
      await settle(600);
      expect(results(), isEmpty);
      expect(chat.searches, isEmpty);
    });
  });
}

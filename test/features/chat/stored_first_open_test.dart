// Seam: MessagesController <-> REAL encrypted MessageStore (DriftMessageStore
// on a temp file) <-> ChatFake, which is never instant and can be held open
// or fail. Written from the Private Chats step 1 Group B contract:
// - open shows the stored newest 50 before the network answers, offline too;
//   a chat already in memory does not read the store;
// - each server page is reconciled (missing rows in its range deleted, live
//   arrivals kept, sync moved, reachedStart on a short page);
// - live inserts, edits, placeholders, landed sends are stored; hideForMe
//   success and vanished rows are removed;
// - loadOlder / jumpToAround answer from the store only inside the stored
//   contiguous range (or a complete chat), else ask the server and store it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';
import '../../support/opener_fakes.dart' show ForgetSpyOpener;
import '../../support/store_spy.dart';
import 'data/store/store_harness.dart';

List<Message> _rows(int from, int to, {String conv = 'c1'}) => [
  for (var i = from; i < to; i++) msg('h$i', conv: conv, t: i, body: 'row $i'),
];

List<String> _ids(int from, int to) => [for (var i = from; i < to; i++) 'h$i'];

void main() {
  late StoreHarness h;
  late DriftMessageStore real;
  late SpyStore store;
  late ChatFake chat;
  late ProviderContainer c;

  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  List<String> serverCalls(String prefix) =>
      chat.calls.where((x) => x.startsWith(prefix)).toList();
  Future<List<String>> storedNewest([String conv = 'c1', int n = 500]) async =>
      ids(await real.newest(conv, limit: n));

  Future<void> open(String id) async {
    c.read(openConversationProvider.notifier).open(id);
    await c.read(messagesProvider.future);
  }

  /// Background work after an open (reconcile, previews) settles.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 300));

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
      ],
    );
    c.listen(messagesProvider, (_, _) {});
    c.listen(olderLoadingProvider, (_, _) {});
  });

  group('open', () {
    test('shows the stored newest 50, oldest first, while the server read is '
        'still in flight', () async {
      await real.upsertAll(_rows(0, 80));
      chat.history['c1'] = [..._rows(0, 80), msg('n80', t: 80)];
      chat.holdMessages();
      c.read(openConversationProvider.notifier).open('c1');

      await eventually(
        () => c.read(messagesProvider).value?.isNotEmpty ?? false,
        reason: 'stored first frame before the network answers',
      );
      expect(shown(), _ids(30, 80));
      expect(store.count('newest:c1'), 1);

      chat.releaseMessages();
      await eventually(() => shown().contains('n80'), reason: 'server page');
      expect(shown().last, 'n80');
    });

    test('a cold open with stored rows never shows an empty list before '
        'the stored rows', () async {
      await real.upsertAll(_rows(0, 80));
      chat.history['c1'] = _rows(0, 80);
      chat.holdMessages();
      final states = <AsyncValue<List<Message>>>[];
      // As the app does it: the chat is opened, then its screen mounts and
      // listens. Every state the screen is handed is recorded.
      // A fresh app: nothing has built messagesProvider before this open.
      final app = ProviderContainer.test(
        overrides: [
          chatRepositoryProvider.overrideWithValue(chat),
          messageStoreProvider.overrideWithValue(store),
        ],
      );
      app.read(openConversationProvider.notifier).open('c1');
      app.listen(
        messagesProvider,
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      await eventually(
        () => states.any((s) => s.value?.isNotEmpty ?? false),
        reason: 'stored rows',
      );
      final firstRows = states.indexWhere((s) => s.value?.isNotEmpty ?? false);
      final before = states.take(firstRows).toList();
      expect(
        before.whereType<AsyncData<List<Message>>>(),
        isEmpty,
        reason: 'a data state came before the stored rows: $before',
      );
      // A loading state carrying [] is fine: the message screen shows its
      // "no messages" text only for AsyncData with an empty timeline.
      expect(before, everyElement(isA<AsyncLoading<List<Message>>>()));
      chat.releaseMessages();
      await app.read(messagesProvider.future);
    });

    test('offline with stored rows shows them, with no error', () async {
      await real.upsertAll(_rows(0, 10));
      chat.messagesResult = const Err(NetworkFailure('offline'));
      c.read(openConversationProvider.notifier).open('c1');
      await eventually(() => serverCalls('messages:c1').isNotEmpty);
      await settle();

      final state = c.read(messagesProvider);
      expect(state.hasError, isFalse, reason: 'stored rows hide the failure');
      expect(shown(), _ids(0, 10));
    });

    test(
      'a chat already shown in memory does not read the store again',
      () async {
        chat.history['c1'] = _rows(0, 20);
        chat.history['c2'] = _rows(0, 5, conv: 'c2');
        await open('c1');
        await settle();
        await open('c2');
        await settle();
        final before = store.count('newest:c1');
        expect(before, lessThanOrEqualTo(1));

        await open('c1');
        await settle();
        expect(store.count('newest:c1'), before);
        expect(shown(), _ids(0, 20));
      },
    );
  });

  group('server page', () {
    test('deletes stored rows in the page range the server no longer lists, '
        'keeps rows outside it, moves the sync state', () async {
      final ghost = Message(
        id: 'ghost',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'deleted elsewhere',
        createdAt: at(45).add(const Duration(seconds: 30)),
      );
      final ghostOld = Message(
        id: 'ghostOld',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'older than the page',
        createdAt: at(2).add(const Duration(seconds: 30)),
      );
      await real.upsertAll([..._rows(0, 60), ghost, ghostOld]);
      chat.history['c1'] = _rows(0, 60); // newest page: h10..h59

      await open('c1');
      await eventually(
        () async => !(await storedNewest()).contains('ghost'),
        reason: 'ghost inside h10..h59 must be deleted',
      );
      final stored = await storedNewest();
      expect(stored, contains('ghostOld'), reason: 'outside the page range');
      expect(stored, containsAll(_ids(0, 60)));

      final sync = await real.syncState('c1');
      expect(sync, isNotNull);
      expect(sync!.newestAt!.isAtSameMomentAs(at(59)), isTrue);
      expect(sync.complete, isFalse, reason: 'page was full (50)');
    });

    test(
      'a short page sets reachedStart: complete, and older stored rows go',
      () async {
        final ghostOld = Message(
          id: 'ghostOld',
          conversationId: 'c1',
          senderId: 'u1',
          body: 'x',
          createdAt: base.subtract(const Duration(minutes: 5)),
        );
        await real.upsertAll([ghostOld]);
        chat.history['c1'] = _rows(0, 30);

        await open('c1');
        await eventually(
          () async => (await real.syncState('c1'))?.complete ?? false,
          reason: 'short page => complete',
        );
        expect(await storedNewest(), _ids(0, 30));
      },
    );

    test('a row that arrived live during the open is kept', () async {
      chat.messagesResult = Ok(_rows(0, 60));
      chat.holdMessages();
      c.read(openConversationProvider.notifier).open('c1');
      await eventually(() => serverCalls('messages:c1').isNotEmpty);
      await eventually(() => serverCalls('incoming:c1').isNotEmpty);
      await settle();
      // Inside the page's time range (h10..h59) but not in the page: the
      // read's snapshot was taken before this insert committed.
      chat.deliver(
        Message(
          id: 'live',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'while opening',
          createdAt: at(55).add(const Duration(seconds: 30)),
        ),
      );
      chat.releaseMessages();
      await c.read(messagesProvider.future);
      await eventually(() async => (await real.syncState('c1')) != null);
      await settle();

      expect(shown(), contains('live'));
      expect(await storedNewest(), contains('live'));
    });
  });

  group('live writes', () {
    setUp(() async {
      chat.history['c1'] = _rows(0, 10);
      await open('c1');
      await settle();
    });

    Future<Message?> storedRow(String id) async => (await real.newest(
      'c1',
      limit: 500,
    )).where((m) => m.id == id).firstOrNull;

    test('a realtime insert is stored', () async {
      // Realtime reaches a live subscription only; wait for it, not a fixed time.
      await eventually(
        () => chat.hasLiveListener('c1'),
        reason: 'never subscribed',
      );
      chat.deliver(msg('n1', t: 20, body: 'fresh'));
      try {
        await eventually(() async => (await storedRow('n1')) != null);
      } on StateError {
        fail(
          'n1 not stored. shown: ${shown().contains('n1')}, listening: '
          '${chat.hasLiveListener('c1')}, store calls: ${store.calls}',
        );
      }
    });

    test('a realtime edit replaces the stored body', () async {
      chat.serverEdit(chat.history['c1']![3], 'changed');
      await eventually(
        () async => (await storedRow('h3'))?.body == 'changed',
        reason: 'edit must be upserted',
      );
    });

    test(
      'a delete-for-everyone placeholder is stored as a placeholder',
      () async {
        chat.deliver(
          Message(
            id: 'h4',
            conversationId: 'c1',
            senderId: 'u1',
            body: '',
            createdAt: at(4),
            deletion: MessageDeletion.placeholder,
            deletedBy: 'u1',
          ),
        );
        await eventually(
          () async =>
              (await storedRow('h4'))?.deletion == MessageDeletion.placeholder,
        );
      },
    );

    test('a vanished row is removed', () async {
      chat.deliver(
        Message(
          id: 'h5',
          conversationId: 'c1',
          senderId: 'u1',
          body: '',
          createdAt: at(5),
          deletion: MessageDeletion.vanished,
        ),
      );
      await eventually(() async => (await storedRow('h5')) == null);
    });

    test(
      'an own send is stored once it lands; a refused one never is',
      () async {
        final queue = c.read(sendQueueProvider.notifier);
        final ok = queue.enqueue('c1', body: 'mine');
        await eventually(() async => (await storedRow(ok.id)) != null);
        expect((await storedRow(ok.id))!.sending, isFalse);

        chat.sendResult = const Err(DeniedFailure());
        final refused = queue.enqueue('c1', body: 'refused');
        await eventually(() => chat.sent.length == 2);
        await settle();
        expect(await storedRow(refused.id), isNull);
      },
    );

    test('hideForMe success removes the row; a refusal keeps it', () async {
      final ctl = c.read(messagesProvider.notifier);
      chat.hideForMeResult = const Err(DeniedFailure());
      await ctl.hideForMe(chat.history['c1']![6]);
      await settle();
      expect(await storedRow('h6'), isNotNull, reason: 'refused: keep');

      chat.hideForMeResult = null;
      await ctl.hideForMe(chat.history['c1']![7]);
      await eventually(() async => (await storedRow('h7')) == null);
    });
  });

  // Group E: a hidden row is forgotten by the opener BEFORE the store drops
  // it (a late reopen could otherwise write it back); a refused hide is not.
  group('hideForMe forgets the row', () {
    setUp(() async {
      c = ProviderContainer.test(
        overrides: [
          chatRepositoryProvider.overrideWithValue(chat),
          messageStoreProvider.overrideWithValue(store),
          messageOpenerProvider.overrideWithValue(
            ForgetSpyOpener((id) => store.calls.add('forget:$id')),
          ),
        ],
      );
      c.listen(messagesProvider, (_, _) {});
      chat.history['c1'] = _rows(0, 10);
      await open('c1');
      await settle();
      store.calls.clear();
    });

    List<String> log() => store.calls
        .where((x) => x.startsWith('forget:') || x.startsWith('remove:'))
        .toList();

    test('Ok: forget, then remove', () async {
      await c.read(messagesProvider.notifier).hideForMe(chat.history['c1']![4]);
      await eventually(() => store.count('remove:h4') == 1);
      expect(log(), ['forget:h4', 'remove:h4']);
    });

    test('Err: neither forgotten nor removed', () async {
      chat.hideForMeResult = const Err(DeniedFailure());
      await c.read(messagesProvider.notifier).hideForMe(chat.history['c1']![4]);
      await settle();
      expect(log(), isEmpty);
    });
  });

  group('loadOlder', () {
    test(
      'inside the stored contiguous range it is answered from the store',
      () async {
        chat.history['c1'] = _rows(0, 150);
        await real.reconcilePage('c1', _rows(0, 150), reachedStart: false);
        await open('c1');
        await settle();
        expect(shown(), _ids(100, 150));

        await c.read(messagesProvider.notifier).loadOlder();
        expect(
          serverCalls('around:'),
          isEmpty,
          reason: 'store covers h50..h99',
        );
        expect(shown(), _ids(50, 150));
      },
    );

    test('a stored block below the contiguous range asks the server', () async {
      chat.history['c1'] = _rows(0, 150);
      await real.upsertAll(_rows(0, 150)); // stored, but never as one range
      await open('c1');
      await settle();

      await c.read(messagesProvider.notifier).loadOlder();
      expect(serverCalls('around:'), hasLength(1));
      expect(shown(), _ids(50, 150));
    });

    test(
      'a short stored block of a not-complete chat asks the server',
      () async {
        chat.history['c1'] = _rows(0, 120);
        await real.reconcilePage('c1', _rows(50, 120), reachedStart: false);
        await real.upsertAll(_rows(30, 50)); // older, but outside the range
        await open('c1');
        await settle();

        await c.read(messagesProvider.notifier).loadOlder();
        expect(serverCalls('around:'), hasLength(1));
        expect(shown().first, 'h20');
      },
    );

    test('a complete chat answers a short block from the store', () async {
      chat.history['c1'] = _rows(0, 70);
      await real.reconcilePage('c1', _rows(0, 70), reachedStart: true);
      await open('c1');
      await settle();
      expect(
        (await real.syncState('c1'))!.complete,
        isTrue,
        reason: 'a full newest page must not undo complete',
      );

      await c.read(messagesProvider.notifier).loadOlder();
      expect(serverCalls('around:'), isEmpty);
      expect(shown(), _ids(0, 70));
    });

    test('a server page is upserted into the store', () async {
      chat.history['c1'] = _rows(0, 150);
      await open('c1');
      await settle();

      await c.read(messagesProvider.notifier).loadOlder();
      expect(serverCalls('around:'), hasLength(1));
      await eventually(
        () async =>
            ids(await real.older('c1', at(100), limit: 50)).length == 50,
        reason: 'h50..h99 from the server must be stored',
      );
      expect(ids(await real.older('c1', at(100), limit: 50)), _ids(50, 100));
    });

    // Contract (Group C): the server path lowers contiguousFrom only when the
    // stored block reaches the oldest shown row; otherwise the sync row stays.
    test('a server page joined to the stored block lowers contiguousFrom; '
        'newestAt and complete stay', () async {
      chat.history['c1'] = _rows(0, 150);
      await open('c1');
      await settle();
      final before = (await real.syncState('c1'))!;
      expect(before.contiguousFrom?.toUtc(), at(100), reason: 'h100..h149');
      expect(shown().first, 'h100', reason: 'the block reaches the oldest row');

      await c.read(messagesProvider.notifier).loadOlder();
      expect(serverCalls('around:'), hasLength(1));
      expect(shown().first, 'h50');
      await eventually(
        () async =>
            (await real.syncState('c1'))?.contiguousFrom?.toUtc() == at(50),
        reason: 'lowered to the oldest row of the server page',
      );
      final after = (await real.syncState('c1'))!;
      expect(after.newestAt?.toUtc(), before.newestAt?.toUtc());
      expect(after.complete, isFalse);
    });

    test('a short server page joined to the stored block marks the chat '
        'complete', () async {
      chat.history['c1'] = _rows(0, 80);
      await open('c1');
      await settle();
      expect((await real.syncState('c1'))!.complete, isFalse);

      await c.read(messagesProvider.notifier).loadOlder();
      expect(shown().first, 'h0');
      await eventually(
        () async => (await real.syncState('c1'))?.complete ?? false,
        reason: 'h0..h29 is shorter than a page: the first message is stored',
      );
      expect((await real.syncState('c1'))!.contiguousFrom?.toUtc(), at(0));
    });

    test('a server page while the shown rows lie below the stored block '
        'leaves the sync row unchanged', () async {
      chat.history['c1'] = _rows(0, 300);
      await open('c1');
      await settle();
      // A jump far back: h50..h150 shown, the stored block is h250..h299.
      await c
          .read(messagesProvider.notifier)
          .jumpToAround(chat.history['c1']![100]);
      await settle();
      expect(shown().first, 'h50');
      final before = (await real.syncState('c1'))!;
      expect(
        before.contiguousFrom!.toUtc().isAfter(at(150)),
        isTrue,
        reason: 'a gap between the shown rows and the stored block: $before',
      );

      await c.read(messagesProvider.notifier).loadOlder();
      expect(serverCalls('around:c1:h50'), hasLength(1));
      expect(shown().first, 'h0');
      await settle();
      final after = (await real.syncState('c1'))!;
      expect(after.contiguousFrom?.toUtc(), before.contiguousFrom?.toUtc());
      expect(after.newestAt?.toUtc(), before.newestAt?.toUtc());
      expect(after.complete, before.complete);
    });
  });

  group('jumpToAround', () {
    test(
      'a window inside contiguousFrom..newestAt comes from the store',
      () async {
        chat.history['c1'] = _rows(0, 150);
        await real.reconcilePage('c1', _rows(20, 150), reachedStart: false);
        await open('c1');
        await settle();

        final r = await c
            .read(messagesProvider.notifier)
            .jumpToAround(chat.history['c1']![80]);
        expect(r, isA<Ok<void>>());
        expect(serverCalls('around:'), isEmpty);
        expect(shown(), contains('h80'));
        expect(shown(), containsAll(_ids(30, 131)));
      },
    );

    test('a window reaching below contiguousFrom asks the server', () async {
      chat.history['c1'] = _rows(0, 150);
      await real.reconcilePage('c1', _rows(20, 150), reachedStart: false);
      await open('c1');
      await settle();

      await c
          .read(messagesProvider.notifier)
          .jumpToAround(chat.history['c1']![30]);
      expect(serverCalls('around:c1:h30'), hasLength(1));
      expect(shown(), contains('h30'));
    });

    test('a server window is upserted into the store', () async {
      chat.history['c1'] = _rows(0, 150);
      await open('c1');
      await settle();

      await c
          .read(messagesProvider.notifier)
          .jumpToAround(chat.history['c1']![40]);
      expect(serverCalls('around:c1:h40'), hasLength(1));
      await eventually(
        () async => ids(await real.around('c1', 'h40')).contains('h0'),
        reason: 'the server window h0..h90 must be stored',
      );
    });
  });
}

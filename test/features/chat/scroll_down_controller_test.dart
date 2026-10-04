// MessagesController's way back down after a jump or a missed catch-up
// (0.30.16), from its contract:
//
// - loadNewer(): not jumped, a no-op with no read. Jumped, reads
//   messagesAround the newest shown non-pending message and appends only
//   rows not already shown with createdAt >= that newest, sorted; vanished
//   rows are dropped. Stays jumped while a page brings messagePageSize or
//   more fresh rows; with fewer it is live again and one verify read of the
//   newest page follows. One read at a time; an epoch-stale answer is
//   dropped; a failure is silent and loadNewer can run again; jumpToAround
//   and build reset the in-flight flag.
// - While jumped a Realtime row does not show; once live it is present.
// - returnToLive() when jumped: the pre-jump live list at once (sync),
//   isJumped false, then a background re-read. A second jump keeps the
//   first stash.
// - Sending while jumped (send queue, or sendImage) returns to live first.
// - A failed resume catch-up keeps the shown list, retries every 5 s up to 5
//   times in a row, then errors; a success resets the count. A first open
//   that fails is still an error.
// - verifyNewest(): re-reads and merges the newest page; a no-op when
//   jumped, loading, without a value or without an open chat; throttled to
//   once per 20 s.
//
// The defect (owner, 0.30.14): after scrolling up, scrolling back down got
// stuck until the chat was reopened.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

const _me = Member(userId: 'me', displayName: 'Maya');

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

final _t0 = DateTime.utc(2026, 1, 1);

Message _m(String id, int minute, {String conv = 'c1'}) => Message(
  id: id,
  conversationId: conv,
  senderId: 'bob',
  body: 'body $id',
  createdAt: _t0.add(Duration(minutes: minute)),
);

List<Message> _history(String conv, int n) => [
  for (var i = 0; i < n; i++) _m('$conv-$i', i, conv: conv),
];

const _offline = NetworkFailure('offline', retryable: true);

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  MessagesController messages() => c.read(messagesProvider.notifier);
  int reads([String id = 'c1']) =>
      chat.calls.where((x) => x == 'messages:$id').length;
  List<String> arounds() =>
      chat.calls.where((x) => x.startsWith('around:')).toList();
  Future<void> idle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));
  List<String> ids(int from, int to) => [
    for (var i = from; i <= to; i++) 'c1-$i',
  ];

  ProviderContainer make({bool listen = true}) {
    final container = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        sessionControllerProvider.overrideWith(_In.new),
      ],
    );
    if (listen) container.listen(messagesProvider, (_, _) {});
    return container;
  }

  Future<void> openC1() async {
    c = make();
    await settled(c);
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
    // The open's own background verify read has run.
    await idle();
  }

  /// Jumps to c1-30: the window c1-0..c1-80 (31 at or before, 50 after).
  Future<void> jump() async {
    final r = await messages().jumpToAround(chat.history['c1']![30]);
    expect(r, isA<Ok<void>>());
    expect(shown(), ids(0, 80), reason: 'fixture: the jumped window');
    expect(messages().isJumped, isTrue);
  }

  group('loadNewer and the jumped window', () {
    setUp(() async {
      chat = ChatFake(latency: const Duration(milliseconds: 2));
      chat.history['c1'] = _history('c1', 600);
      chat.history['c2'] = _history('c2', 20);
      await openC1();
    });

    test('not jumped: a no-op, no repository call', () async {
      final before = List.of(chat.calls);
      await messages().loadNewer();
      await idle();
      expect(chat.calls, before);
      expect(shown(), ids(550, 599));
    });

    test('jumped: reads around the newest shown row and appends the fresh '
        'page; 50 fresh rows keep it jumped', () async {
      await jump();
      await messages().loadNewer();
      await idle();
      expect(arounds().last, 'around:c1:c1-80');
      expect(shown(), ids(0, 130));
      expect(messages().isJumped, isTrue, reason: '50 fresh: not live yet');
    });

    test('only unseen rows at or after the newest are appended, sorted; a '
        'vanished row is dropped', () async {
      await jump();
      // The answer repeats the shown rows, carries an older unseen row, a
      // fresh row that vanished (deleted for everyone), and the fresh ones
      // newest first. 51 fresh rows: it stays jumped, so no verify read
      // tidies the list afterwards.
      final rows = chat.history['c1']!;
      final gone = rows[84];
      chat.messagesAroundResult = Ok([
        _m('ghost-older', 40),
        for (var i = 31; i <= 80; i++) rows[i],
        for (var i = 131; i >= 81; i--)
          if (i == 84)
            Message(
              id: gone.id,
              conversationId: 'c1',
              senderId: gone.senderId,
              body: '',
              createdAt: gone.createdAt,
              deletion: MessageDeletion.vanished,
            )
          else
            rows[i],
      ]);
      await messages().loadNewer();
      await idle();
      expect(messages().isJumped, isTrue, reason: 'fixture: no verify read');
      final after = shown();
      expect(
        after,
        isNot(contains('ghost-older')),
        reason: 'older than newest',
      );
      expect(after, isNot(contains('c1-84')), reason: 'vanished');
      expect(after, [
        ...ids(0, 83),
        ...ids(85, 131),
      ], reason: 'no duplicates, fresh rows sorted');
    });

    test('paging down reaches the live end: not jumped, newest shown, one '
        'verify read of the newest page', () async {
      await jump();
      for (var i = 0; i < 20 && messages().isJumped; i++) {
        await messages().loadNewer();
        await idle(10);
      }
      expect(messages().isJumped, isFalse);
      final readsAtLive = reads();
      await idle();
      expect(shown().last, 'c1-599');
      expect(shown(), ids(0, 599), reason: 'no gap, no duplicate, sorted');
      expect(reads() - readsAtLive, lessThanOrEqualTo(1));
      // Exactly one verify read happened since the window started paging.
      expect(
        chat.calls.reversed
            .takeWhile((x) => !x.startsWith('around:'))
            .where((x) => x == 'messages:c1'),
        hasLength(1),
        reason: 'one verify read after the last page',
      );
    });

    test('one read at a time', () async {
      await jump();
      final held = chat.holdAround();
      final first = messages().loadNewer();
      await idle(10);
      final second = messages().loadNewer();
      await idle(10);
      expect(arounds().where((x) => x == 'around:c1:c1-80'), hasLength(1));
      held.complete();
      await first;
      await second;
      expect(arounds().length, 2, reason: 'the jump and one page only');
    });

    test('a failure is silent and loadNewer can run again', () async {
      await jump();
      chat.messagesAroundResult = const Err(_offline);
      await messages().loadNewer();
      await idle();
      expect(c.read(messagesProvider).hasError, isFalse);
      expect(shown(), ids(0, 80));
      chat.messagesAroundResult = null;
      await messages().loadNewer();
      await idle();
      expect(shown(), ids(0, 130));
    });

    test('a page answered after a chat switch is dropped', () async {
      await jump();
      final held = chat.holdAround();
      final pending = messages().loadNewer();
      await idle(10);
      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);
      held.complete();
      await pending;
      await idle();
      expect(shown().every((id) => id.startsWith('c2-')), isTrue);
    });

    test('a page answered after a new jump is dropped, and the new jump can '
        'page down at once', () async {
      await jump();
      final held = chat.holdAround();
      final stale = messages().loadNewer();
      await idle(10);
      // A new jump while the page is in flight.
      await messages().jumpToAround(chat.history['c1']![300]);
      expect(shown().first, 'c1-250');
      await messages().loadNewer();
      await idle();
      expect(
        arounds().last,
        'around:c1:c1-350',
        reason: 'jumpToAround reset the in-flight flag',
      );
      held.complete();
      await stale;
      await idle();
      expect(shown(), isNot(contains('c1-81')), reason: 'stale page dropped');
      expect(shown().last, 'c1-400');
    });

    test(
      'while jumped a Realtime row does not show; once live it does',
      () async {
        await jump();
        final late = _m('c1-new', 60 * 24 * 2);
        chat.deliver(late);
        await idle();
        expect(shown(), isNot(contains('c1-new')), reason: 'jumped: no gap');
        for (var i = 0; i < 20 && messages().isJumped; i++) {
          await messages().loadNewer();
          await idle(10);
        }
        await idle();
        expect(messages().isJumped, isFalse);
        expect(shown().last, 'c1-new');
      },
    );
  });

  group('returnToLive', () {
    setUp(() async {
      chat = ChatFake(latency: const Duration(milliseconds: 2));
      chat.history['c1'] = _history('c1', 600);
      await openC1();
    });

    test('jumped: the pre-jump live list in the same call, then a '
        'background re-read', () async {
      final live = shown();
      await jump();
      final asked = reads();
      messages().returnToLive();
      expect(messages().isJumped, isFalse);
      expect(shown(), live, reason: 'synchronously, before any read lands');
      await idle();
      expect(reads(), greaterThan(asked), reason: 'background re-read');
      expect(shown(), live);
    });

    test('a second jump keeps the first stash', () async {
      final live = shown();
      await jump();
      await messages().jumpToAround(chat.history['c1']![300]);
      expect(shown(), contains('c1-300'), reason: 'fixture');
      messages().returnToLive();
      expect(shown(), live, reason: 'the live list, not the first window');
      await idle();
    });
  });

  group('sending while jumped', () {
    setUp(() async {
      chat = ChatFake(latency: const Duration(milliseconds: 2), self: 'me');
      chat.history['c1'] = _history('c1', 600);
      await openC1();
    });

    test('a text from the send queue returns to live and shows at the '
        'bottom with no gap', () async {
      await jump();
      chat.holdWrite();
      c.read(sendQueueProvider.notifier).enqueue('c1', body: 'hello');
      await idle(10);
      expect(messages().isJumped, isFalse);
      final rows = c.read(messagesProvider).requireValue;
      expect(rows.last.body, 'hello');
      expect(rows[rows.length - 2].id, 'c1-599', reason: 'no gap');
      expect(rows.map((m) => m.id), isNot(contains('c1-30')));
      chat.releaseWrite();
      await idle();
    });

    test(
      'a photo returns to live and shows at the bottom with no gap',
      () async {
        await jump();
        chat.holdSendImage();
        final sending = messages().sendImage(
          chosen: PickedImage(
            bytes: Uint8List.fromList([1, 2, 3]),
            contentType: 'image/jpeg',
            extension: 'jpg',
          ),
        );
        await idle(10);
        expect(messages().isJumped, isFalse);
        final rows = c.read(messagesProvider).requireValue;
        expect(
          rows.last.localImage,
          isNotNull,
          reason: 'the pending photo at the bottom',
        );
        expect(rows[rows.length - 2].id, 'c1-599', reason: 'no gap');
        chat.releaseSendImage();
        await sending;
        await idle();
      },
    );
  });

  group('failed resume catch-up', () {
    // testWidgets runs in fake time, so the 5 s retry timer is driven by
    // pump(duration) rather than waited for.
    void failReads() {
      chat.history.remove('c1');
      chat.messagesResult = const Err(_offline);
    }

    Future<void> elapse(WidgetTester t, Duration d) async {
      const step = Duration(milliseconds: 100);
      var left = d;
      while (left > Duration.zero) {
        final s = left < step ? left : step;
        await t.pump(s);
        left -= s;
      }
    }

    Future<void> openFake(WidgetTester t) async {
      c = make();
      addTearDown(c.dispose);
      await settled(c);
      c.read(openConversationProvider.notifier).open('c1');
      await elapse(t, const Duration(milliseconds: 200));
      expect(c.read(messagesProvider).requireValue, hasLength(10));
    }

    setUp(() {
      chat = ChatFake();
      chat.history['c1'] = _history('c1', 10);
    });

    testWidgets('a failed read keeps the list, retries every 5 s up to 5 '
        'times, then errors', (t) async {
      await openFake(t);
      final live = shown();
      failReads();
      final mark = reads();
      messages().catchUp();
      await elapse(t, const Duration(milliseconds: 100));
      expect(reads(), mark + 1, reason: 'the catch-up read');
      expect(c.read(messagesProvider).hasError, isFalse);
      expect(shown(), live);

      for (var retry = 1; retry <= 5; retry++) {
        await elapse(t, const Duration(milliseconds: 4700));
        expect(reads(), mark + retry, reason: 'not before 5 s');
        await elapse(t, const Duration(milliseconds: 300));
        expect(reads(), mark + 1 + retry, reason: 'retry $retry');
        if (retry < 5) {
          expect(c.read(messagesProvider).hasError, isFalse);
          expect(shown(), live);
        }
      }
      expect(c.read(messagesProvider).hasError, isTrue);
      await elapse(t, const Duration(seconds: 30));
      expect(reads(), mark + 6, reason: 'no retry after giving up');
    });

    testWidgets('a failed join keeps the list too, and retries', (t) async {
      await openFake(t);
      final live = shown();
      chat.incomingResult = const Err(_offline);
      messages().catchUp();
      await elapse(t, const Duration(milliseconds: 100));
      expect(c.read(messagesProvider).hasError, isFalse);
      expect(shown(), live);
      chat.incomingResult = null;
      final mark = chat.calls.length;
      await elapse(t, const Duration(seconds: 6));
      expect(chat.calls.sublist(mark), contains('incoming:c1'));
      expect(c.read(messagesProvider).hasError, isFalse);
    });

    testWidgets('a success resets the count', (t) async {
      await openFake(t);
      failReads();
      messages().catchUp();
      await elapse(t, const Duration(milliseconds: 100));
      await elapse(t, const Duration(seconds: 15)); // three retries fail
      chat.history['c1'] = _history('c1', 11);
      await elapse(t, const Duration(seconds: 5)); // the fourth succeeds
      expect(shown().last, 'c1-10');
      failReads();
      messages().catchUp();
      await elapse(t, const Duration(milliseconds: 100));
      await elapse(t, const Duration(seconds: 20)); // four retries fail
      expect(
        c.read(messagesProvider).hasError,
        isFalse,
        reason: 'five failures since the success, not nine',
      );
      expect(shown().last, 'c1-10');
      await elapse(t, const Duration(seconds: 5)); // the fifth fails
      expect(c.read(messagesProvider).hasError, isTrue);
    });

    test('on first open, a failure with no list is an error', () async {
      failReads();
      c = make();
      await settled(c);
      c.read(openConversationProvider.notifier).open('c1');
      await expectLater(c.read(messagesProvider.future), throwsA(anything));
      expect(c.read(messagesProvider).hasError, isTrue);
    });
  });

  group('verifyNewest', () {
    setUp(() {
      chat = ChatFake(latency: const Duration(milliseconds: 2));
      chat.history['c1'] = _history('c1', 600);
    });

    test('a row missed by Realtime appears at the bottom; a second call '
        'within 20 s reads nothing', () async {
      await openC1();
      chat.loseRealtime();
      chat.deliver(_m('missed', 60 * 24));
      await idle();
      expect(shown(), isNot(contains('missed')), reason: 'fixture: missed');
      final mark = reads();
      messages().verifyNewest();
      await idle();
      expect(reads(), mark + 1);
      expect(shown().last, 'missed');
      messages().verifyNewest();
      await idle();
      expect(reads(), mark + 1, reason: 'throttled');
    });

    test('a no-op while jumped', () async {
      await openC1();
      await jump();
      final mark = reads();
      messages().verifyNewest();
      await idle();
      expect(reads(), mark);
      expect(messages().isJumped, isTrue);
    });

    test('a no-op while loading', () async {
      await openC1();
      chat.holdMessages();
      messages().catchUp();
      await idle(10);
      final mark = reads();
      messages().verifyNewest();
      await idle(10);
      expect(reads(), mark);
      chat.releaseMessages();
      await idle();
    });

    test('a no-op with no value', () async {
      chat.history.remove('c1');
      chat.messagesResult = const Err(_offline);
      c = make(listen: false);
      await settled(c);
      c.read(openConversationProvider.notifier).open('c1');
      // Built for the first time with c1 open: no earlier value at all.
      c.listen(messagesProvider, (_, _) {});
      await idle();
      expect(c.read(messagesProvider).hasError, isTrue, reason: 'fixture');
      // No list to show: the first open failed. (Riverpod may still carry
      // an empty previous value; for the screen that is no value.)
      expect(
        c.read(messagesProvider).value ?? const <Message>[],
        isEmpty,
        reason: 'fixture',
      );
      final mark = reads();
      messages().verifyNewest();
      await idle();
      expect(reads(), mark);
    });

    test('a no-op with no open conversation', () async {
      c = make();
      await settled(c);
      await c.read(messagesProvider.future);
      final before = List.of(chat.calls);
      messages().verifyNewest();
      await idle();
      expect(chat.calls.where((x) => x.startsWith('messages:')), isEmpty);
      expect(chat.calls, before);
    });
  });
}

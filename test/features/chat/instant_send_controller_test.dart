// A text message is shown the moment it is sent (2026-09-28), and each chat
// sends through its own queue (2026-09-28, "Unsent text stays in each
// chat"): the controllers' side. Written from the contract only -- what the
// message list holds, what the server is asked and in which order, what a
// failure leaves behind -- never from how the queue is built.
//
// The server here answers only when the test says so. A send that is
// answered at once cannot show a message that was never shown before the
// answer, cannot show two sends overlapping, and cannot show an echo
// arriving before the answer. Retries and backoff are in
// send_queue_retry_test.dart, under fake time.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';
import '../../support/held_send_chat.dart';

Message row(String id, {String conv = 'c1', String from = 'u2'}) => Message(
  id: id,
  conversationId: conv,
  senderId: from,
  body: 'text of $id',
  createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
);

final uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> open(HeldSendChat chat, String id) async {
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  c.listen(messagesProvider, (_, _) {});
  c.read(openConversationProvider.notifier).open(id);
  await c.read(messagesProvider.future);
  return c;
}

/// Lets every queued microtask and zero timer run: the queue's next step,
/// a delivered echo, a completed answer.
Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<Message> shown(ProviderContainer c) =>
    c.read(messagesProvider).requireValue;
List<String> ids(ProviderContainer c) => [for (final m in shown(c)) m.id];
Iterable<Message> pending(ProviderContainer c) =>
    shown(c).where((m) => m.sending);
SendQueueController queue(ProviderContainer c) =>
    c.read(sendQueueProvider.notifier);
Message enqueue(ProviderContainer c, String body, {Message? replyTo}) =>
    queue(c).enqueue('c1', body: body, replyTo: replyTo);

void main() {
  test('a sending message is pending; an ordinary one is not', () {
    final base = row('m1');
    expect(base.sending, isFalse, reason: 'sending defaults to false');
    expect(base.isPending, isFalse);
    final sending = Message(
      id: 'p',
      conversationId: 'c1',
      senderId: 'u1',
      body: 'x',
      createdAt: DateTime.now(),
      sending: true,
    );
    expect(sending.isPending, isTrue);
  });

  test('randomMessageId is a lowercase v4 UUID, different every time', () {
    final many = [for (var i = 0; i < 500; i++) randomMessageId()];
    for (final id in many) {
      expect(id, matches(uuidV4));
    }
    expect(many.toSet(), hasLength(500));
  });

  group('the pending message', () {
    test('is in the list synchronously, before the server is asked: trimmed, '
        'mine, replying to the reply target, which is then cleared; the '
        'server is asked with the same id', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');
      final m1 = shown(c).single;
      c.read(replyingToProvider.notifier).start(m1);

      List<Message>? whenAsked;
      chat.onAsk = (_) => whenAsked = shown(c);

      final returned = enqueue(c, '  hello  ', replyTo: m1);

      // No await between the call and these reads.
      final p = shown(c).last;
      expect(p.id, returned.id);
      expect(p.id, matches(uuidV4));
      expect(p.sending, isTrue);
      expect(p.isPending, isTrue);
      expect(p.body, 'hello');
      expect(p.conversationId, 'c1');
      expect(p.senderId, me.userId, reason: 'drawn on my side');
      expect(p.replyTo, 'm1');
      expect(ids(c).first, 'm1');
      expect(c.read(replyingToProvider), isNull);
      expect(c.read(sendQueueProvider)['c1']?.map((m) => m.id), [p.id]);

      await flush();
      expect(chat.asked, hasLength(1));
      expect(chat.asked.single.id, p.id, reason: 'the id the phone chose');
      expect(chat.asked.single.replyTo, 'm1');
      expect(chat.asked.single.conversationId, 'c1');
      expect(
        whenAsked?.map((m) => m.id),
        contains(p.id),
        reason: 'shown before the server was asked, not after',
      );

      chat.ok(0);
      await flush();
      expect(ids(c), ['m1', p.id], reason: 'the stored row keeps its id');
      expect(pending(c), isEmpty);
      expect(c.read(sendQueueProvider)['c1'] ?? const [], isEmpty);
    });

    test('quick sends each get their own id', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      for (var i = 0; i < 50; i++) {
        enqueue(c, 'm$i');
      }
      final pendingIds = [for (final m in pending(c)) m.id];
      expect(pendingIds, hasLength(50));
      expect(
        pendingIds.toSet(),
        hasLength(50),
        reason: 'two bubbles sharing an id cannot be replaced one by one',
      );
    });

    test('sending clears that chat\'s draft', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final drafts = c.read(draftsProvider.notifier)
        ..setText('c1', 'hello')
        ..setText('c2', 'other chat');
      enqueue(c, 'hello');
      expect(drafts.draftFor('c1').text, isEmpty);
      expect(c.read(draftsProvider).containsKey('c1'), isFalse);
      expect(drafts.draftFor('c2').text, 'other chat');
    });
  });

  group('order', () {
    test('three quick sends reach the server one at a time, in typed order, '
        'and stay in that order', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');

      final a = enqueue(c, 'a');
      final b = enqueue(c, 'b');
      final d = enqueue(c, 'c');
      expect([for (final m in pending(c)) m.body], ['a', 'b', 'c']);
      expect(c.read(sendQueueProvider)['c1']?.map((m) => m.body), [
        'a',
        'b',
        'c',
      ], reason: 'oldest first');

      await flush();
      expect([for (final x in chat.asked) x.body], ['a']);
      chat.ok(0);
      await flush();
      expect([for (final x in chat.asked) x.body], ['a', 'b']);
      chat.ok(1);
      await flush();
      expect([for (final x in chat.asked) x.body], ['a', 'b', 'c']);
      chat.ok(2);
      await flush();

      expect(chat.maxInFlight, 1, reason: 'never two sends in flight at once');
      expect([for (final x in chat.asked) x.id], [a.id, b.id, d.id]);
      expect(ids(c), [a.id, b.id, d.id]);
      expect(pending(c), isEmpty);
    });
  });

  group('the server copy', () {
    test('replaces the pending message where it stands', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');

      final p = enqueue(c, 'mine');
      await flush();
      chat.deliver(row('m2')); // someone else writes meanwhile
      await flush();
      expect(ids(c), ['m1', p.id, 'm2']);
      expect(shown(c)[1].sending, isTrue);

      chat.ok(0);
      await flush();
      expect(ids(c), ['m1', p.id, 'm2']);
      expect(shown(c)[1].sending, isFalse);
    });

    test('the echo arriving before the answer: shown once', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');

      final p = enqueue(c, 'mine');
      await flush();
      chat.echo(0);
      await flush();
      expect(ids(c), ['m1', p.id], reason: 'the echo replaces, not appends');
      chat.ok(0);
      await flush();

      expect(ids(c), ['m1', p.id]);
      expect(pending(c), isEmpty);
    });

    test('the answer arriving before the echo: shown once', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');

      final p = enqueue(c, 'mine');
      await flush();
      chat.ok(0);
      await flush();
      chat.echo(0);
      await flush();

      expect(ids(c), ['m1', p.id]);
      expect(pending(c), isEmpty);
    });
  });

  group('a refused send', () {
    test('stops the queue: the refused and every later send leave the list '
        'and go back to the draft in typed order, with the earliest reply '
        'target and one notice', () async {
      final m1 = row('m1'), m2 = row('m2');
      final chat = HeldSendChat()..history['c1'] = [m1, m2];
      final c = await open(chat, 'c1');

      enqueue(c, 'a', replyTo: m1);
      enqueue(c, 'b');
      enqueue(c, 'c', replyTo: m2);
      expect(pending(c), hasLength(3));

      await flush();
      const failure = DeniedFailure();
      chat.fail(0, failure);
      await flush();

      expect(
        [for (final x in chat.asked) x.body],
        ['a'],
        reason: 'the queue stops at the refusal',
      );
      expect(pending(c), isEmpty);
      expect(ids(c), ['m1', 'm2']);
      expect(c.read(sendQueueProvider)['c1'] ?? const [], isEmpty);

      final drafts = c.read(draftsProvider.notifier);
      final d = drafts.draftFor('c1');
      expect(d.text, 'a\nb\nc');
      expect(d.replyTo?.id, 'm1', reason: 'the earliest reply target');
      expect(drafts.consumeFailure('c1'), same(failure));
      expect(drafts.consumeFailure('c1'), isNull, reason: 'shown once');
      expect(drafts.draftFor('c1').text, 'a\nb\nc', reason: 'text stays');
    });

    test('a non-retryable NetworkFailure is a refusal too', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      enqueue(c, 'a');
      await flush();
      const failure = NetworkFailure('The server could not do that.');
      chat.fail(0, failure);
      await flush();
      expect(chat.asked, hasLength(1), reason: 'not retried');
      expect(pending(c), isEmpty);
      final drafts = c.read(draftsProvider.notifier);
      expect(drafts.draftFor('c1').text, 'a');
      expect(drafts.consumeFailure('c1'), same(failure));
    });

    test('goes in front of what was typed since', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      enqueue(c, 'first');
      c.read(draftsProvider.notifier).setText('c1', 'typed since');
      await flush();
      chat.fail(0, const DeniedFailure());
      await flush();
      expect(
        c.read(draftsProvider.notifier).draftFor('c1').text,
        'first\ntyped since',
      );
    });

    test('a refusal mid-queue keeps what the server already has', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');

      final a = enqueue(c, 'a');
      enqueue(c, 'b');
      enqueue(c, 'c');
      await flush();
      chat.ok(0);
      await flush();
      chat.fail(1, const DeniedFailure());
      await flush();

      expect(chat.asked, hasLength(2));
      expect(ids(c), [a.id]);
      final d = c.read(draftsProvider.notifier).draftFor('c1');
      expect(d.text, 'b\nc');
      expect(d.replyTo, isNull);
    });

    test('the next send after a refusal still goes out', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');

      enqueue(c, 'a');
      await flush();
      chat.fail(0, const DeniedFailure());
      await flush();

      final b = enqueue(c, 'b');
      await flush();
      expect([for (final x in chat.asked) x.body], ['a', 'b']);
      chat.ok(1);
      await flush();
      expect(ids(c), [b.id]);
    });
  });

  group('leaving the conversation mid-send', () {
    test('queued sends still go to the conversation they were typed in, and '
        'never appear in the one opened since', () async {
      final chat = HeldSendChat()
        ..history['c1'] = [row('m1')]
        ..history['c2'] = [row('n1', conv: 'c2')];
      final c = await open(chat, 'c1');

      enqueue(c, 'a');
      enqueue(c, 'b');
      await flush();

      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);
      expect(ids(c), ['n1']);

      chat.ok(0);
      await flush();
      chat.ok(1);
      await flush();

      expect(
        [for (final x in chat.asked) (x.conversationId, x.body)],
        [('c1', 'a'), ('c1', 'b')],
      );
      expect(ids(c), ['n1'], reason: 'c1\'s messages never land in c2');
    });

    test('reopening mid-send shows the pending messages again, then the '
        'stored ones in place', () async {
      final chat = HeldSendChat()
        ..history['c1'] = [row('m1')]
        ..history['c2'] = [row('n1', conv: 'c2')];
      final c = await open(chat, 'c1');

      final a = enqueue(c, 'a');
      final b = enqueue(c, 'b');
      await flush();
      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);

      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      await flush();
      expect(ids(c), ['m1', a.id, b.id]);
      expect([for (final m in pending(c)) m.id], [a.id, b.id]);

      chat.ok(0);
      await flush();
      chat.ok(1);
      await flush();
      expect(ids(c), ['m1', a.id, b.id]);
      expect(pending(c), isEmpty);
    });

    test('a refusal after leaving is kept for that conversation; the open '
        'one\'s reply target and draft are not touched', () async {
      final m1 = row('m1');
      final n1 = row('n1', conv: 'c2');
      final chat = HeldSendChat()
        ..history['c1'] = [m1]
        ..history['c2'] = [n1];
      final c = await open(chat, 'c1');

      enqueue(c, 'a', replyTo: m1);
      await flush();

      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);
      c.read(replyingToProvider.notifier).start(n1);
      c.read(draftsProvider.notifier).setText('c2', 'for c2');

      chat.fail(0, const DeniedFailure());
      await flush();

      expect(c.read(replyingToProvider)?.id, 'n1');
      expect(ids(c), ['n1']);
      final drafts = c.read(draftsProvider.notifier);
      expect(drafts.consumeFailure('c2'), isNull);
      expect(drafts.draftFor('c2').text, 'for c2');
      expect(drafts.draftFor('c1').text, 'a');
      expect(drafts.draftFor('c1').replyTo?.id, 'm1');
      expect(drafts.consumeFailure('c1'), isA<DeniedFailure>());
      expect(drafts.consumeFailure('c1'), isNull, reason: 'read once');
    });
  });

  group('chats are independent', () {
    test('a send stuck in c1 never delays c2', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final q = queue(c);
      q.enqueue('c1', body: 'a1');
      q.enqueue('c1', body: 'a2');
      await flush();
      final b = q.enqueue('c2', body: 'b1');
      await flush();

      expect(
        [for (final x in chat.asked) (x.conversationId, x.body)],
        [('c1', 'a1'), ('c2', 'b1')],
        reason: 'c2 went out while c1 still waits',
      );
      chat.ok(1);
      await flush();
      expect(c.read(sendQueueProvider)['c2'] ?? const [], isEmpty);
      expect(c.read(sendQueueProvider)['c1']?.map((m) => m.body), ['a1', 'a2']);
      expect(chat.asked[1].id, b.id);
      chat.ok(0);
      await flush();
      chat.ok(2);
      await flush();
    });

    test('a refusal in c1 never stops c2', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final q = queue(c);
      q.enqueue('c1', body: 'a1');
      q.enqueue('c2', body: 'b1');
      q.enqueue('c2', body: 'b2');
      await flush();

      chat.fail(0, const DeniedFailure());
      await flush();
      expect(c.read(draftsProvider.notifier).draftFor('c1').text, 'a1');
      expect(c.read(draftsProvider.notifier).draftFor('c2').text, isEmpty);

      final b1 = chat.asked.indexWhere((x) => x.body == 'b1');
      chat.ok(b1);
      await flush();
      expect(
        [for (final x in chat.asked) x.body],
        containsAll(['b1', 'b2']),
        reason: 'c2 carries on',
      );
      chat.ok(chat.asked.indexWhere((x) => x.body == 'b2'));
      await flush();
      expect(c.read(sendQueueProvider)['c2'] ?? const [], isEmpty);
      expect(c.read(draftsProvider.notifier).consumeFailure('c2'), isNull);
    });
  });

  test('a retryable failure keeps everything queued: nothing drafted, no '
      'notice, the pending messages stay', () async {
    final chat = HeldSendChat();
    final c = await open(chat, 'c1');
    final a = enqueue(c, 'a');
    final b = enqueue(c, 'b');
    await flush();
    chat.fail(0, const NetworkFailure('No connection', retryable: true));
    await flush();

    expect([for (final m in pending(c)) m.id], [a.id, b.id]);
    expect(c.read(sendQueueProvider)['c1']?.map((m) => m.id), [a.id, b.id]);
    final drafts = c.read(draftsProvider.notifier);
    expect(drafts.draftFor('c1').text, isEmpty);
    expect(drafts.consumeFailure('c1'), isNull);
    expect(chat.asked, hasLength(1), reason: 'b is not tried past a');
    // Leave nothing scheduled behind the test.
    queue(c).pauseForBackground();
  });
}

// A text message is shown the moment it is sent (2026-09-28): the
// controller's side. Written from the contract only -- what the message
// list holds, what the server is asked and in which order, and what a
// failure leaves behind -- never from how the queue is built.
//
// The server here answers only when the test says so. A send that is
// answered at once cannot show a message that was never shown before the
// answer, cannot show two sends overlapping, and cannot show an echo
// arriving before the answer.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
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

  group('the pending message', () {
    test('is in the list synchronously, before the server is asked: trimmed, '
        'mine, replying to the reply target, which is then cleared', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');
      c.read(replyingToProvider.notifier).start(shown(c).single);

      List<Message>? whenAsked;
      chat.onAsk = (_) => whenAsked = shown(c);

      final result = c.read(messagesProvider.notifier).send('  hello  ');

      // No await between the call and these reads.
      final p = shown(c).last;
      expect(p.sending, isTrue);
      expect(p.isPending, isTrue);
      expect(p.id, startsWith('pending-'));
      expect(p.body, 'hello');
      expect(p.conversationId, 'c1');
      expect(p.senderId, me.userId, reason: 'drawn on my side');
      expect(p.replyTo, 'm1');
      expect(ids(c).first, 'm1');
      expect(c.read(replyingToProvider), isNull);

      await flush();
      expect(chat.asked, hasLength(1));
      expect(chat.asked.single.replyTo, 'm1');
      expect(chat.asked.single.conversationId, 'c1');
      expect(
        whenAsked?.map((m) => m.id),
        contains(p.id),
        reason: 'shown before the server was asked, not after',
      );

      chat.ok(0);
      final r = await result;
      expect((r as Ok<Message>).value.id, 'srv-1');
    });

    test('quick sends each get their own pending id', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final ctrl = c.read(messagesProvider.notifier);
      for (var i = 0; i < 50; i++) {
        unawaited(ctrl.send('m$i'));
      }
      final pendingIds = [for (final m in pending(c)) m.id];
      expect(pendingIds, hasLength(50));
      expect(
        pendingIds.toSet(),
        hasLength(50),
        reason: 'two bubbles sharing an id cannot be replaced one by one',
      );
    });
  });

  group('order', () {
    test('three quick sends reach the server one at a time, in typed order, '
        'and stay in that order', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final ctrl = c.read(messagesProvider.notifier);

      final a = ctrl.send('a');
      final b = ctrl.send('b');
      final d = ctrl.send('c');
      expect([for (final m in pending(c)) m.body], ['a', 'b', 'c']);

      await flush();
      expect([for (final x in chat.asked) x.body], ['a']);
      chat.ok(0);
      await flush();
      expect([for (final x in chat.asked) x.body], ['a', 'b']);
      chat.ok(1);
      await flush();
      expect([for (final x in chat.asked) x.body], ['a', 'b', 'c']);
      chat.ok(2);

      for (final r in await Future.wait([a, b, d])) {
        expect(r, isA<Ok<Message>>());
      }
      expect(chat.maxInFlight, 1, reason: 'never two sends in flight at once');
      expect(ids(c), ['srv-1', 'srv-2', 'srv-3']);
      expect(pending(c), isEmpty);
    });
  });

  group('the server copy', () {
    test('replaces the pending message where it stands', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');

      final r = c.read(messagesProvider.notifier).send('mine');
      await flush();
      chat.deliver(row('m2')); // someone else writes meanwhile
      await flush();
      final pendingId = pending(c).single.id;
      expect(ids(c), ['m1', pendingId, 'm2']);

      chat.ok(0);
      await r;
      await flush();
      expect(ids(c), ['m1', 'srv-1', 'm2']);
      expect(shown(c)[1].sending, isFalse);
    });

    test('the echo arriving before the answer: shown once', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');

      final r = c.read(messagesProvider.notifier).send('mine');
      await flush();
      chat.echo(0);
      await flush();
      chat.ok(0);
      await r;
      await flush();

      expect(ids(c).where((id) => id == 'srv-1'), hasLength(1));
      expect(pending(c), isEmpty);
      expect(ids(c), ['m1', 'srv-1']);
    });

    test('the answer arriving before the echo: shown once', () async {
      final chat = HeldSendChat()..history['c1'] = [row('m1')];
      final c = await open(chat, 'c1');

      final r = c.read(messagesProvider.notifier).send('mine');
      await flush();
      chat.ok(0);
      await r;
      await flush();
      chat.echo(0);
      await flush();

      expect(ids(c), ['m1', 'srv-1']);
      expect(pending(c), isEmpty);
    });
  });

  group('a failed send', () {
    test('stops the queue: the failed and every later send are removed, '
        'all answered with the same failure, their text and reply target '
        'kept for the composer', () async {
      final m1 = row('m1'), m2 = row('m2');
      final chat = HeldSendChat()..history['c1'] = [m1, m2];
      final c = await open(chat, 'c1');
      final ctrl = c.read(messagesProvider.notifier);
      final reply = c.read(replyingToProvider.notifier);

      reply.start(m1);
      final a = ctrl.send('a');
      final b = ctrl.send('b');
      reply.start(m2);
      final d = ctrl.send('c');
      expect(pending(c), hasLength(3));

      await flush();
      const failure = NetworkFailure('No connection');
      chat.fail(0, failure);
      final results = await Future.wait([a, b, d]);
      await flush();

      for (final r in results) {
        expect((r as Err<Message>).failure, same(failure));
      }
      expect(
        [for (final x in chat.asked) x.body],
        ['a'],
        reason: 'the queue stops at the failure',
      );
      expect(pending(c), isEmpty);
      expect(ids(c), ['m1', 'm2']);

      final stashed = c.read(sendFailureProvider)['c1'];
      expect(stashed, isNotNull);
      expect(stashed!.bodies, ['a', 'b', 'c']);
      expect(stashed.replyTo?.id, 'm1', reason: 'the earliest reply target');
      expect(stashed.failure, same(failure));
      expect(
        c.read(replyingToProvider)?.id,
        'm1',
        reason: 'the conversation is still open: the reply comes back live',
      );
    });

    test('a failure mid-queue keeps what the server already has', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final ctrl = c.read(messagesProvider.notifier);

      final a = ctrl.send('a');
      final b = ctrl.send('b');
      final d = ctrl.send('c');
      await flush();
      chat.ok(0);
      await flush();
      chat.fail(1, const DeniedFailure());

      expect(await a, isA<Ok<Message>>());
      expect(await b, isA<Err<Message>>());
      expect(await d, isA<Err<Message>>());
      await flush();
      expect(chat.asked, hasLength(2));
      expect(ids(c), ['srv-1']);
      expect(c.read(sendFailureProvider)['c1']!.bodies, ['b', 'c']);
      expect(c.read(sendFailureProvider)['c1']!.replyTo, isNull);
      expect(c.read(replyingToProvider), isNull);
    });

    test('the next send after a failure still goes out', () async {
      final chat = HeldSendChat();
      final c = await open(chat, 'c1');
      final ctrl = c.read(messagesProvider.notifier);

      final a = ctrl.send('a');
      await flush();
      chat.fail(0, const NetworkFailure('No connection'));
      await a;

      final b = ctrl.send('b');
      await flush();
      expect([for (final x in chat.asked) x.body], ['a', 'b']);
      chat.ok(1);
      expect(await b, isA<Ok<Message>>());
      await flush();
      expect(ids(c), ['srv-2']);
    });
  });

  group('leaving the conversation mid-send', () {
    test('queued sends still go to the conversation they were typed in, and '
        'never appear in the one opened since', () async {
      final chat = HeldSendChat()
        ..history['c1'] = [row('m1')]
        ..history['c2'] = [row('n1', conv: 'c2')];
      final c = await open(chat, 'c1');
      final ctrl = c.read(messagesProvider.notifier);

      final a = ctrl.send('a');
      final b = ctrl.send('b');
      await flush();

      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);
      expect(ids(c), ['n1']);

      chat.ok(0);
      await flush();
      chat.ok(1);
      expect(await a, isA<Ok<Message>>());
      expect(await b, isA<Ok<Message>>());
      await flush();

      expect(
        [for (final x in chat.asked) (x.conversationId, x.body)],
        [('c1', 'a'), ('c1', 'b')],
      );
      expect(ids(c), ['n1'], reason: 'c1\'s messages never land in c2');
    });

    test('a failure after leaving is kept for that conversation; the open '
        'one\'s reply target is not touched', () async {
      final m1 = row('m1');
      final n1 = row('n1', conv: 'c2');
      final chat = HeldSendChat()
        ..history['c1'] = [m1]
        ..history['c2'] = [n1];
      final c = await open(chat, 'c1');

      c.read(replyingToProvider.notifier).start(m1);
      final a = c.read(messagesProvider.notifier).send('a');
      await flush();

      c.read(openConversationProvider.notifier).open('c2');
      await c.read(messagesProvider.future);
      c.read(replyingToProvider.notifier).start(n1);

      chat.fail(0, const NetworkFailure('No connection'));
      expect(await a, isA<Err<Message>>());
      await flush();

      expect(c.read(replyingToProvider)?.id, 'n1');
      expect(ids(c), ['n1']);
      final failures = c.read(sendFailureProvider.notifier);
      expect(failures.consume('c2'), isNull);
      final kept = failures.consume('c1');
      expect(kept?.bodies, ['a']);
      expect(kept?.replyTo?.id, 'm1');
      expect(failures.consume('c1'), isNull, reason: 'read once');
    });
  });
}

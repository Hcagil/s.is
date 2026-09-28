// SendQueueController under a failing connection, on the test clock
// ("Unsent text stays in each chat", 2026-09-28, with the offline queue):
// a retryable failure keeps the message queued and retries it with the SAME
// id after 1, 2, 4, then 5 s (capped); backgrounding stops the retries,
// returning retries every waiting chat at once from a fresh ladder. Written
// from the contract, never from how the queue is built.
//
// testWidgets for its fake clock: a backoff is only proven by showing
// nothing happens one millisecond before it is due and the retry happens
// when it is.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/held_send_chat.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

const offline = NetworkFailure('No connection', retryable: true);

/// Runs every microtask and zero timer, without moving the clock.
Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump();
  }
}

Future<ProviderContainer> start(WidgetTester t, HeldSendChat chat) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  await hop(t);
  // Setup leaves a short timer of its own (not the queue's); let it run
  // before the clock is measured.
  await t.pump(const Duration(milliseconds: 1));
  expect(c.read(sessionControllerProvider).value, isA<Allowed>());
  return c;
}

/// Asks the server has not answered yet, for [conv].
int open(HeldSendChat chat, String conv) => chat.asked
    .where((a) => a.conversationId == conv && !a.answer.isCompleted)
    .length;

List<String> queued(ProviderContainer c, String conv) => [
  for (final m in c.read(sendQueueProvider)[conv] ?? const <Message>[]) m.id,
];

/// Fails ask [i] as offline, then shows its retry is due exactly [due]
/// later: nothing a millisecond before, the same id right at it.
Future<void> expectRetryAfter(
  WidgetTester t,
  HeldSendChat chat,
  int i,
  Duration due,
) async {
  chat.fail(i, offline);
  await hop(t);
  final before = chat.asked.length;
  await t.pump(due - const Duration(milliseconds: 1));
  await hop(t);
  expect(
    chat.asked,
    hasLength(before),
    reason: 'retried before ${due.inSeconds} s had passed',
  );
  await t.pump(const Duration(milliseconds: 1));
  await hop(t);
  expect(
    chat.asked,
    hasLength(before + 1),
    reason: 'not retried once ${due.inSeconds} s had passed',
  );
  expect(chat.asked.last.id, chat.asked[i].id, reason: 'the same message');
}

void main() {
  testWidgets('offline: retried with the same id after 1, 2, 4, 5, 5 s, the '
      'message queued and never drafted, then stored once back', (t) async {
    final chat = HeldSendChat();
    final c = await start(t, chat);
    final q = c.read(sendQueueProvider.notifier);
    final a = q.enqueue('c1', body: 'a');
    final b = q.enqueue('c1', body: 'b');
    await hop(t);
    expect(chat.asked, hasLength(1));

    var i = 0;
    for (final s in [1, 2, 4, 5, 5]) {
      await expectRetryAfter(t, chat, i++, Duration(seconds: s));
      expect(queued(c, 'c1'), [a.id, b.id], reason: 'nothing leaves');
      final drafts = c.read(draftsProvider.notifier);
      expect(drafts.draftFor('c1').text, isEmpty, reason: 'not drafted');
      expect(drafts.consumeFailure('c1'), isNull, reason: 'no notice');
    }
    expect(
      {for (final x in chat.asked) x.id},
      {a.id},
      reason: 'every attempt is the same message: the same id',
    );
    expect(open(chat, 'c1'), 1, reason: 'b never overtakes a');

    chat.ok(i);
    await hop(t);
    expect(chat.asked.last.id, b.id, reason: 'b follows at once');
    chat.ok(i + 1);
    await hop(t);
    expect(queued(c, 'c1'), isEmpty);
    expect(c.read(draftsProvider.notifier).consumeFailure('c1'), isNull);
  });

  testWidgets('the pending message keeps its place and id through every '
      'retry, then becomes the stored one in place', (t) async {
    final chat = HeldSendChat()
      ..history['c1'] = [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'hi',
          createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      ];
    final c = await start(t, chat);
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await hop(t);
    final a = c.read(sendQueueProvider.notifier).enqueue('c1', body: 'a');
    await hop(t);

    await expectRetryAfter(t, chat, 0, const Duration(seconds: 1));
    await expectRetryAfter(t, chat, 1, const Duration(seconds: 2));
    List<Message> shown() => c.read(messagesProvider).requireValue;
    expect([for (final m in shown()) m.id], ['m1', a.id]);
    expect(shown().last.sending, isTrue);

    chat.ok(2);
    await hop(t);
    expect([for (final m in shown()) m.id], ['m1', a.id]);
    expect(shown().last.sending, isFalse);
  });

  testWidgets('a retry the server refuses goes back to the draft with one '
      'notice', (t) async {
    final chat = HeldSendChat();
    final c = await start(t, chat);
    c.read(sendQueueProvider.notifier)
      ..enqueue('c1', body: 'a')
      ..enqueue('c1', body: 'b');
    await hop(t);
    await expectRetryAfter(t, chat, 0, const Duration(seconds: 1));
    chat.fail(1, const DeniedFailure());
    await hop(t);

    expect(queued(c, 'c1'), isEmpty);
    final drafts = c.read(draftsProvider.notifier);
    expect(drafts.draftFor('c1').text, 'a\nb');
    expect(drafts.consumeFailure('c1'), isA<DeniedFailure>());
    await t.pump(const Duration(seconds: 30));
    expect(chat.asked, hasLength(2), reason: 'a refusal is not retried');
  });

  testWidgets('a chat waiting to retry never delays another chat', (t) async {
    final chat = HeldSendChat();
    final c = await start(t, chat);
    final q = c.read(sendQueueProvider.notifier);
    q.enqueue('c1', body: 'a');
    await hop(t);
    chat.fail(0, offline);
    await hop(t);

    final b = q.enqueue('c2', body: 'b');
    await hop(t);
    expect(chat.asked.last.id, b.id, reason: 'c2 did not wait for c1');
    chat.ok(1);
    await hop(t);
    expect(queued(c, 'c2'), isEmpty);
    expect(queued(c, 'c1'), hasLength(1));

    await t.pump(const Duration(seconds: 1));
    await hop(t);
    chat.ok(2);
    await hop(t);
    expect(queued(c, 'c1'), isEmpty);
  });

  group('backgrounding', () {
    testWidgets('pauses the retries without losing anything', (t) async {
      final chat = HeldSendChat();
      final c = await start(t, chat);
      final q = c.read(sendQueueProvider.notifier);
      final a = q.enqueue('c1', body: 'a');
      await hop(t);
      chat.fail(0, offline);
      await hop(t);

      q.pauseForBackground();
      await t.pump(const Duration(minutes: 5));
      await hop(t);
      expect(chat.asked, hasLength(1), reason: 'no retry while hidden');
      expect(queued(c, 'c1'), [a.id]);

      q.resumeForeground();
      await hop(t);
      expect(chat.asked, hasLength(2), reason: 'returning retries at once');
      expect(chat.asked.last.id, a.id);
      chat.ok(1);
      await hop(t);
      expect(queued(c, 'c1'), isEmpty);
    });

    testWidgets('returning retries every waiting chat at once, from a fresh '
        'ladder', (t) async {
      final chat = HeldSendChat();
      final c = await start(t, chat);
      final q = c.read(sendQueueProvider.notifier)
        ..enqueue('c1', body: 'a')
        ..enqueue('c2', body: 'b');
      await hop(t);
      expect(chat.asked, hasLength(2)); // [c1 a, c2 b]
      // c1 fails twice: its next retry would be 4 s away.
      await expectRetryAfter(t, chat, 0, const Duration(seconds: 1));
      chat.fail(1, offline); // c2 now waits too
      chat.fail(2, offline); // c1's second attempt
      await hop(t);
      expect(chat.asked, hasLength(3));

      q.pauseForBackground();
      await t.pump(const Duration(minutes: 1));
      await hop(t);
      expect(chat.asked, hasLength(3), reason: 'no retry while hidden');

      q.resumeForeground();
      await hop(t);
      final retried = chat.asked.sublist(3);
      expect([for (final x in retried) x.conversationId]..sort(), [
        'c1',
        'c2',
      ], reason: 'every waiting chat, at once');
      final c1 = chat.asked.lastIndexWhere((x) => x.conversationId == 'c1');
      final c2 = chat.asked.lastIndexWhere((x) => x.conversationId == 'c2');
      chat.ok(c2);
      await hop(t);
      // c1 fails again: 1 s, not the 4 s it had reached before.
      await expectRetryAfter(t, chat, c1, const Duration(seconds: 1));
      chat.ok(chat.asked.length - 1);
      await hop(t);
      expect(queued(c, 'c1'), isEmpty);
      expect(queued(c, 'c2'), isEmpty);
    });

    testWidgets('returning while a send is still in flight does not send it '
        'twice at once', (t) async {
      final chat = HeldSendChat();
      final c = await start(t, chat);
      final q = c.read(sendQueueProvider.notifier)..enqueue('c1', body: 'a');
      await hop(t);
      expect(open(chat, 'c1'), 1);

      q
        ..pauseForBackground()
        ..resumeForeground();
      await hop(t);
      expect(
        chat.asked,
        hasLength(1),
        reason: 'one attempt in flight per chat',
      );
      chat.ok(0);
      await hop(t);
      expect(queued(c, 'c1'), isEmpty);
      expect(chat.asked, hasLength(1));
    });
  });
}

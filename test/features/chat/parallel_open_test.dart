// Opening a chat with the Realtime join and the history read in parallel
// (0.30.12), from the contract handed to QA -- never the implementation:
//
// - MessagesController joins (ChatRepository.incoming) and reads (messages)
//   together. Live events that arrive before the read lands are kept and
//   merged with it by id: nothing from before the join to after the read is
//   lost, each message shows once, in createdAt order.
// - A background verify re-read closes the window where the read was served
//   before the join took effect. It merges by id and adopts only NEWER state
//   (a delete, or a later editedAt) -- it never reverts a live delete or edit
//   -- and it is skipped when the member deleted or hid something
//   optimistically meanwhile.
// - A chat seen earlier in this run shows from memory at once (at most 8
//   chats are remembered; an account change clears them -- see
//   account_switch_providers_test.dart): build is AsyncLoading carrying that
//   list, and the message screen draws it with no spinner.
// - A failed join or read is an AsyncError; closing the chat mid-open
//   cancels a join that lands late.
//
// _Server is this suite's own stand-in for the database and Realtime, built
// to be inconvenient: a read is a snapshot taken the moment the server
// serves it, and its answer can be held in flight after that; a subscription
// is live only once the server confirms it, so a write before that is never
// delivered; and updates (an edit, a delete) arrive as the changed row.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

import 'package:sis/l10n/app_localizations.dart';

const maya = Member(userId: 'u1', displayName: 'Maya');
final _t0 = DateTime.utc(2026, 10, 1, 12);

Message m(String id, int minute, {String conv = 'c1', String from = 'u2'}) =>
    Message(
      id: id,
      conversationId: conv,
      senderId: from,
      body: 'body $id',
      createdAt: _t0.add(Duration(minutes: minute)),
    );

Message edited(Message x, String body) => Message(
  id: x.id,
  conversationId: x.conversationId,
  senderId: x.senderId,
  body: body,
  createdAt: x.createdAt,
  editedAt: x.createdAt.add(const Duration(hours: 1)),
);

Message deleted(Message x) => Message(
  id: x.id,
  conversationId: x.conversationId,
  senderId: x.senderId,
  body: '',
  createdAt: x.createdAt,
  deletion: MessageDeletion.placeholder,
  deletedBy: x.senderId,
);

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(maya);
}

/// How one upcoming read of a conversation behaves.
class Plan {
  /// Held: the query has not reached the server yet; nothing is snapshotted.
  Completer<void>? serve;

  /// Held: the server answered (the snapshot is taken), but the answer is
  /// still on its way to the phone.
  Completer<void>? answer;

  /// Completes the moment the snapshot is taken.
  final served = Completer<void>();

  void releaseServe() => serve?.complete();
  void releaseAnswer() => answer?.complete();
}

class _Server extends ChatFake {
  _Server() : super(self: 'u1');

  /// The table: conversation -> id -> current row.
  final table = <String, Map<String, Message>>{};
  final _plans = <String, List<Plan>>{};
  final _live = <String, List<StreamController<Message>>>{};

  Result<List<Message>>? readError;
  Result<Stream<Message>>? joinError;

  /// Held: the server has not confirmed the subscription.
  Completer<void>? joinGate;
  int cancelled = 0;

  /// Held: a send is still on its way to the server.
  Completer<void>? sendGate;

  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String body,
    String? replyTo,
  }) async {
    if (sendGate case final gate?) await gate.future;
    return super.send(
      id: id,
      conversationId: conversationId,
      body: body,
      replyTo: replyTo,
    );
  }

  int live(String conv) => _live[conv]?.length ?? 0;
  int reads(String conv) => calls.where((c) => c == 'messages:$conv').length;

  void seed(List<Message> rows) {
    for (final r in rows) {
      (table[r.conversationId] ??= {})[r.id] = r;
    }
  }

  /// An INSERT or UPDATE: the row changes, and every live subscription to
  /// its conversation receives the new row. Nothing else does.
  void write(Message r) {
    (table[r.conversationId] ??= {})[r.id] = r;
    for (final s in [...?_live[r.conversationId]]) {
      s.add(r);
    }
  }

  Plan holdServe(String conv) => _plan(conv, Plan()..serve = Completer<void>());
  Plan holdAnswer(String conv) =>
      _plan(conv, Plan()..answer = Completer<void>());
  Plan _plan(String conv, Plan p) {
    (_plans[conv] ??= []).add(p);
    return p;
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    calls.add('messages:$conversationId');
    final queue = _plans[conversationId];
    final plan = (queue == null || queue.isEmpty) ? null : queue.removeAt(0);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (plan?.serve case final gate?) await gate.future;
    if (readError case final failed?) return failed;
    final snapshot = [...?table[conversationId]?.values]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    plan?.served.complete();
    if (plan?.answer case final gate?) await gate.future;
    return Ok(snapshot);
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
    calls.add('incoming:$conversationId');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (joinGate case final gate?) await gate.future;
    if (joinError case final failed?) return failed;
    // Live from the confirmation on; what arrives before listen() is held
    // for the listener, as a single-subscription stream holds it.
    late final StreamController<Message> s;
    s = StreamController<Message>(
      onCancel: () {
        _live[conversationId]?.remove(s);
        cancelled++;
      },
    );
    (_live[conversationId] ??= []).add(s);
    return Ok(s.stream);
  }

  /// The server deletes at once; the Realtime echo is slow (never comes
  /// here), so only the member's own optimistic change shows it.
  @override
  Future<Result<void>> deleteForEveryone(Message message) async {
    (table[message.conversationId] ??= {})[message.id] = deleted(message);
    return const Ok(null);
  }

  @override
  Future<Result<void>> hideForMe(Message message) async {
    hidden.add(message.id);
    table[message.conversationId]?.remove(message.id);
    return const Ok(null);
  }
}

/// Waits until [ok] holds, failing after [within].
Future<void> eventually(
  bool Function() ok, {
  Duration within = const Duration(seconds: 2),
  String reason = '',
}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('never happened: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> quiet() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  late _Server server;
  late ProviderContainer c;
  late List<AsyncValue<List<Message>>> states;

  setUp(() async {
    server = _Server();
    states = [];
    c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(server),
        sessionControllerProvider.overrideWith(_In.new),
      ],
    );
    await c.read(sessionControllerProvider.future);
    c.listen(messagesProvider, (_, next) => states.add(next));
  });

  List<Message> rows() => c.read(messagesProvider).value ?? const [];
  List<String> shown() => [for (final x in rows()) x.id];
  Message row(String id) => rows().singleWhere((x) => x.id == id);
  MessagesController ctl() => c.read(messagesProvider.notifier);
  void open(String id) => c.read(openConversationProvider.notifier).open(id);

  /// Opens [id] and lets the open, the join and the verify read finish.
  Future<void> openSettled(String id) async {
    open(id);
    await c.read(messagesProvider.future);
    await eventually(() => server.live(id) == 1, reason: 'joined');
    await eventually(() => server.reads(id) >= 2, reason: 'verify read');
    await quiet();
  }

  group('nothing is lost between the join and the read', () {
    test('join and read start together, not one after the other', () async {
      server.joinGate = Completer<void>();
      server.seed([m('m1', 1)]);
      open('c1');
      await eventually(
        () => server.calls.contains('messages:c1'),
        reason: 'the read waited for the join to be confirmed',
      );
      expect(server.calls, contains('incoming:c1'));
      server.joinGate!.complete();
      await c.read(messagesProvider.future);
      await quiet();
    });

    test('an insert after the join, before the read is served, shows once '
        '(it is in the read AND on the stream)', () async {
      server.seed([m('m1', 1)]);
      final first = server.holdServe('c1');
      final verify = server.holdServe('c1');
      open('c1');
      await eventually(() => server.live('c1') == 1, reason: 'joined');
      server.write(m('m2', 2));
      first.releaseServe();
      await c.read(messagesProvider.future);
      await quiet();

      expect(shown(), ['m1', 'm2'], reason: 'before the verify read');
      verify.releaseServe();
      await eventually(() => verify.served.isCompleted);
      await quiet();
      expect(shown(), ['m1', 'm2'], reason: 'after the verify read');
    });

    test('an insert after the read was served, before it lands, is kept and '
        'shown -- without waiting for the verify read', () async {
      server.seed([m('m1', 1), m('m3', 3)]);
      final first = server.holdAnswer('c1');
      final verify = server.holdServe('c1');
      open('c1');
      await first.served.future;
      await eventually(() => server.live('c1') == 1, reason: 'joined');
      server.write(m('m4', 4));
      server.write(m('m2', 2)); // older than m3: lands in its place
      await quiet();
      first.releaseAnswer();
      await c.read(messagesProvider.future);
      await quiet();

      expect(shown(), [
        'm1',
        'm2',
        'm3',
        'm4',
      ], reason: 'live events before the read landed must be buffered');
      verify.releaseServe();
      await eventually(() => server.reads('c1') >= 2);
      await quiet();
      expect(shown(), ['m1', 'm2', 'm3', 'm4']);
    });

    test('an insert while the join is still pending, after the read was '
        'served, reaches neither -- the verify read brings it in', () async {
      server.seed([m('m1', 1)]);
      server.joinGate = Completer<void>();
      final first = server.holdAnswer('c1');
      open('c1');
      await first.served.future;
      server.write(m('m2', 2)); // nobody is live: never delivered
      expect(server.live('c1'), 0, reason: 'the window must be real');
      first.releaseAnswer();
      server.joinGate!.complete();
      await c.read(messagesProvider.future);

      await eventually(
        () => shown().contains('m2'),
        reason: 'the verify read must close the read-before-join window',
      );
      await quiet();
      expect(shown(), ['m1', 'm2']);

      server.write(m('m3', 3));
      await eventually(() => shown().contains('m3'), reason: 'still live');
      expect(shown(), ['m1', 'm2', 'm3']);
    });

    test('a live message newer than the verify read\'s snapshot is not '
        'dropped by it', () async {
      server.seed([m('m1', 1)]);
      server.holdAnswer('c1').answer!.complete(); // first read: plain
      final verify = server.holdAnswer('c1');
      open('c1');
      await c.read(messagesProvider.future);
      await verify.served.future;
      await eventually(() => server.live('c1') == 1);
      server.write(m('m2', 2));
      await eventually(() => shown().contains('m2'));
      verify.releaseAnswer();
      await quiet();
      expect(shown(), ['m1', 'm2']);
    });

    test("another conversation's messages are never shown", () async {
      server.seed([m('m1', 1), m('x1', 1, conv: 'c2')]);
      await openSettled('c1');
      server.write(m('x2', 2, conv: 'c2'));
      await quiet();
      expect(shown(), ['m1']);
    });
  });

  group('the verify read adopts only newer state', () {
    test('a stale FIRST read never reverts a live edit or delete that '
        'arrived while it was in flight', () async {
      final m1 = m('m1', 1), m2 = m('m2', 2);
      server.seed([m1, m2]);
      final first = server.holdAnswer('c1');
      final verify = server.holdServe('c1');
      open('c1');
      await first.served.future;
      await eventually(() => server.live('c1') == 1);
      server.write(edited(m1, 'fixed'));
      server.write(deleted(m2));
      await quiet();
      first.releaseAnswer();
      await c.read(messagesProvider.future);
      await quiet();

      expect(shown(), ['m1', 'm2']);
      expect(row('m1').body, 'fixed');
      expect(row('m2').isDeleted, isTrue);
      verify.releaseServe();
      await eventually(() => server.reads('c1') >= 2);
      await quiet();
      expect(row('m1').body, 'fixed');
      expect(row('m2').isDeleted, isTrue);
    });

    test('a stale VERIFY read never reverts a live edit or delete', () async {
      final m1 = m('m1', 1), m2 = m('m2', 2);
      server.seed([m1, m2]);
      server.holdAnswer('c1').answer!.complete(); // first read: plain
      final second = server.holdAnswer('c1');
      open('c1');
      await c.read(messagesProvider.future);
      await second.served.future; // its snapshot: m1, m2 as they were
      await eventually(() => server.live('c1') == 1);
      server.write(edited(m1, 'fixed'));
      server.write(deleted(m2));
      await eventually(() => row('m2').isDeleted && row('m1').body == 'fixed');

      second.releaseAnswer();
      await quiet();
      expect(row('m1').body, 'fixed', reason: 'a live edit was reverted');
      expect(row('m2').isDeleted, isTrue, reason: 'a live delete was undone');
      expect(shown(), ['m1', 'm2']);
    });

    test('a newer verify read is adopted: an edit and a delete made while '
        'the join was pending (the stream never had them)', () async {
      final m1 = m('m1', 1), m2 = m('m2', 2);
      server.seed([m1, m2]);
      server.joinGate = Completer<void>();
      final first = server.holdAnswer('c1');
      open('c1');
      await first.served.future;
      server.write(edited(m1, 'fixed'));
      server.write(deleted(m2));
      first.releaseAnswer();
      server.joinGate!.complete();
      await c.read(messagesProvider.future);

      await eventually(
        () => row('m1').body == 'fixed' && row('m2').isDeleted,
        reason: 'the newer read was not adopted',
      );
      expect(shown(), ['m1', 'm2']);
    });
  });

  group('an optimistic change is never undone by the verify read', () {
    Future<Plan> openWithVerifyHeld() async {
      server.seed([m('m1', 1, from: 'u1'), m('m2', 2, from: 'u1')]);
      server.holdAnswer('c1').answer!.complete(); // first read: plain
      final verify = server.holdAnswer('c1');
      open('c1');
      await c.read(messagesProvider.future);
      await verify.served.future; // snapshot holds m1 as it was
      await eventually(() => server.live('c1') == 1);
      return verify;
    }

    test('hide for me', () async {
      final verify = await openWithVerifyHeld();
      final r = await ctl().hideForMe(row('m1'));
      expect(r, isA<Ok<void>>());
      expect(shown(), ['m2'], reason: 'fixture: the hide is optimistic');

      verify.releaseAnswer();
      await quiet();
      expect(shown(), ['m2'], reason: 'the verify read brought it back');
    });

    test('delete for everyone (its echo not here yet)', () async {
      final verify = await openWithVerifyHeld();
      final r = await ctl().deleteForEveryone(row('m1'));
      expect(r, isA<Ok<void>>());
      expect(row('m1').isDeleted, isTrue, reason: 'fixture: optimistic');

      verify.releaseAnswer();
      await quiet();
      expect(row('m1').isDeleted, isTrue, reason: 'the verify read undid it');
    });
  });

  group('chats seen earlier this run show from memory', () {
    test('A, B, then A again: A shows at once, before any read lands, and '
        'then settles with each message once', () async {
      server.seed([m('a1', 1, conv: 'cA'), m('a2', 2, conv: 'cA')]);
      server.seed([m('b1', 1, conv: 'cB')]);
      await openSettled('cA');
      await openSettled('cB');

      final held = server.holdServe('cA');
      server.joinGate = Completer<void>();
      open('cA');
      final now = c.read(messagesProvider);
      expect(now.hasError, isFalse);
      expect(
        [for (final x in now.value ?? const <Message>[]) x.id],
        ['a1', 'a2'],
        reason: 'A must show from memory in the same frame',
      );

      held.releaseServe();
      server.joinGate!.complete();
      await c.read(messagesProvider.future);
      await quiet();
      expect(shown(), ['a1', 'a2']);
    });

    test('opening B never shows A\'s remembered list, not even while B '
        'loads; a late answer for A never lands in B', () async {
      server.seed([m('a1', 1, conv: 'cA')]);
      server.seed([m('b1', 1, conv: 'cB')]);
      await openSettled('cA');

      final lateA = server.holdAnswer('cA');
      server.holdServe('cA'); // A's verify, if it runs again
      open('cB'); // leave A
      await c.read(messagesProvider.future);
      open('cA');
      await lateA.served.future;
      final mark = states.length;
      final bRead = server.holdServe('cB');
      open('cB');
      lateA.releaseAnswer();
      await quiet();
      bRead.releaseServe();
      await c.read(messagesProvider.future);
      await quiet();

      for (final s in states.sublist(mark)) {
        final ids = [for (final x in s.value ?? const <Message>[]) x.id];
        expect(ids.where((id) => id.startsWith('a')), isEmpty, reason: '$s');
      }
      expect(shown(), ['b1']);
    });

    test(
      'at most 8 chats are remembered: the 9th pushes out the first',
      () async {
        for (var i = 1; i <= 9; i++) {
          server.seed([m('k$i', 1, conv: 'k$i')]);
          await openSettled('k$i');
        }
        open('k0'); // leave k9 too

        final k1 = server.holdServe('k1');
        server.joinGate = Completer<void>();
        open('k1');
        expect(
          c.read(messagesProvider).value ?? const <Message>[],
          isEmpty,
          reason: 'k1 is the 9th most recent: it should be forgotten',
        );
        k1.releaseServe();
        server.joinGate!.complete();
        server.joinGate = null;
        await c.read(messagesProvider.future);
        await quiet();

        final k9 = server.holdServe('k9');
        server.joinGate = Completer<void>();
        open('k9');
        expect(
          [
            for (final x in c.read(messagesProvider).value ?? const <Message>[])
              x.id,
          ],
          ['k9'],
          reason: 'the most recent chat is remembered',
        );
        k9.releaseServe();
        server.joinGate!.complete();
        await c.read(messagesProvider.future);
        await quiet();
      },
    );

    test('a bubble still sending when the chat was left is not remembered: '
        'it never comes back from memory after its send resolved', () async {
      server.seed([m('p1', 1)]);
      server.seed([m('b1', 1, conv: 'c2')]);
      await openSettled('c1');
      server.sendGate = Completer<void>();
      c.read(sendQueueProvider.notifier).enqueue('c1', body: 'on its way');
      await eventually(
        () => rows().any((x) => x.isPending),
        reason: 'the pending bubble shows',
      );
      await openSettled('c2');
      server.sendGate!.complete();
      await quiet(); // the send resolves while c1 is closed

      final held = server.holdServe('c1');
      server.joinGate = Completer<void>();
      open('c1');
      final now = c.read(messagesProvider).value ?? const <Message>[];
      expect([for (final x in now) x.id], contains('p1'), reason: 'memory');
      expect(
        now.where((x) => x.isPending),
        isEmpty,
        reason: 'a resolved send must not come back as a pending bubble',
      );
      held.releaseServe();
      server.joinGate!.complete();
      await c.read(messagesProvider.future);
    });
  });

  group('failures', () {
    test('a join that fails is an AsyncError', () async {
      server.seed([m('m1', 1)]);
      server.joinError = const Err(NetworkFailure('realtime down'));
      open('c1');
      await expectLater(c.read(messagesProvider.future), throwsA(anything));
      expect(c.read(messagesProvider).hasError, isTrue);
    });

    test('a read that fails is an AsyncError, and the join is let go when '
        'the chat closes', () async {
      server.seed([m('m1', 1)]);
      server.readError = const Err(NetworkFailure('offline'));
      open('c1');
      await expectLater(c.read(messagesProvider.future), throwsA(anything));
      expect(c.read(messagesProvider).hasError, isTrue);
      await quiet();

      c.read(openConversationProvider.notifier).close();
      await eventually(
        () => server.live('c1') == 0,
        reason: 'the join listener outlived the chat',
      );
    });

    test('closing the chat mid-open cancels a join that lands late, and its '
        'messages are never shown', () async {
      server.seed([m('m1', 1)]);
      server.joinGate = Completer<void>();
      open('c1');
      await eventually(() => server.calls.contains('incoming:c1'));
      c.read(openConversationProvider.notifier).close();
      await quiet();

      server.joinGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        (live: server.live('c1'), cancelled: server.cancelled),
        (live: 0, cancelled: 1),
        reason: 'the late join was never cancelled: ${server.calls}',
      );
      server.write(m('m2', 2));
      await quiet();
      expect(shown(), isNot(contains('m2')));
    });

    test('switching to another chat mid-open: the first chat\'s late join is '
        'cancelled and its messages never reach the second', () async {
      server.seed([m('m1', 1), m('b1', 1, conv: 'c2')]);
      final gate = server.joinGate = Completer<void>();
      open('c1');
      await eventually(() => server.calls.contains('incoming:c1'));
      server.joinGate = null; // c2's own join is prompt
      open('c2');
      await c.read(messagesProvider.future);
      await quiet();

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      server.write(m('m2', 2));
      await quiet();
      expect(shown(), ['b1'], reason: "c1's message shown in c2");
      expect(
        server.live('c1'),
        0,
        reason: 'the late join was never cancelled: ${server.calls}',
      );
    });

    test('disposing mid-open cancels a join that lands late', () async {
      server.seed([m('m1', 1)]);
      server.joinGate = Completer<void>();
      open('c1');
      await eventually(() => server.calls.contains('incoming:c1'));
      c.dispose();

      server.joinGate!.complete();
      await eventually(
        () => server.cancelled >= 1 && server.live('c1') == 0,
        reason: 'the late join was never cancelled',
      );
    });
  });

  testWidgets('the message screen draws a remembered chat in the first '
      'frame, with no wait shown', (t) async {
    final s = _Server()..seed([m('a1', 1, conv: 'cA'), m('b1', 1, conv: 'cB')]);
    final container = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(s),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_In.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      ],
    );
    addTearDown(container.dispose);
    await t.runAsync(() => container.read(sessionControllerProvider.future));
    container.read(openConversationProvider.notifier).open('cA');
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MessageScreen(title: 'Ann'),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-a1')), findsOneWidget);
    container.read(openConversationProvider.notifier).open('cB');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-b1')), findsOneWidget);

    final held = s.holdServe('cA');
    s.joinGate = Completer<void>();
    container.read(openConversationProvider.notifier).open('cA');
    await t.pump();

    expect(find.byKey(const ValueKey('message-a1')), findsOneWidget);
    expect(sisWait, findsNothing, reason: 'a spinner over stored content');

    held.releaseServe();
    s.joinGate!.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-a1')), findsOneWidget);
  });
}

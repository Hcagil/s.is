// Messages strictly per chat (0.30.7), written from the contract:
//
// - Switching the open conversation (A -> B, A -> null -> B, or straight
//   after opening What's new, before any read finished) never shows A's rows
//   as B's: while B loads, messagesProvider's value is empty or absent, and
//   once loaded it holds B's rows only. The screen likewise.
// - A Realtime row whose conversationId is not the open chat's is ignored,
//   whether it arrives on the old chat's subscription after the switch, on
//   B's own stream, or buffered while B's first read is in flight.
// - openConversation(A) leaving while markRead(A) is slow, with B opened
//   meanwhile: the open conversation stays B -- not closed, not restored.
// - A same-chat catchUp keeps the shown list while it reloads.
//
// The fake: ChatFake (QA-written) plus per-conversation read holds and a
// "leak" that puts any row on a chat's subscription, as a mis-filtered or
// shared Realtime channel would.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const maya = Member(userId: 'u1', displayName: 'Maya');
final _t0 = DateTime.utc(2026, 10, 1, 12);

Message msg(String id, String conv, {int minute = 0, String from = 'u2'}) =>
    Message(
      id: id,
      conversationId: conv,
      senderId: from,
      body: 'body $id',
      createdAt: _t0.add(Duration(minutes: minute)),
    );

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(maya);
}

class _PerChatFake extends ChatFake {
  _PerChatFake() : super(self: 'u1', latency: const Duration(milliseconds: 2));

  final _held = <String, Completer<void>>{};
  final _leaks = <String, StreamController<Message>>{};

  /// [messages] for [id] stays in flight until [releaseRead].
  void holdRead(String id) => _held[id] = Completer<void>();
  void releaseRead(String id) => _held.remove(id)?.complete();

  /// Puts [m] on [streamOf]'s subscription whatever its conversationId.
  void leak(String streamOf, Message m) => _leaks[streamOf]?.add(m);

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    final held = _held[conversationId];
    if (held != null) await held.future;
    return super.messages(conversationId);
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
    final r = await super.incoming(conversationId);
    if (r is! Ok<Stream<Message>>) return r;
    final leak = _leaks[conversationId] ??= StreamController.broadcast();
    return Ok(
      Stream<Message>.multi((out) {
        final a = r.value.listen(out.add, onError: out.addError);
        final b = leak.stream.listen(out.add);
        out.onCancel = () async {
          await a.cancel();
          await b.cancel();
        };
      }, isBroadcast: true),
    );
  }
}

Future<void> eventually(
  bool Function() ok, {
  Duration within = const Duration(seconds: 2),
  String reason = '',
}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('never happened: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  late _PerChatFake chat;
  late ProviderContainer c;

  ProviderContainer make() => ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      sessionControllerProvider.overrideWith(_In.new),
    ],
  );

  setUp(() async {
    chat = _PerChatFake();
    chat.history['sis'] = [msg('w1', 'sis', from: 'sys'), msg('w2', 'sis')];
    chat.history['a'] = [msg('a1', 'a'), msg('a2', 'a', minute: 1)];
    chat.history['b'] = [msg('b1', 'b')];
    chat.conversationsResult = const Ok([
      Conversation(id: 'sis', title: 'SIS', isSystem: true),
      Conversation(id: 'a', title: 'A'),
      Conversation(id: 'b', title: 'B'),
    ]);
    c = make();
    await c.read(sessionControllerProvider.future);
  });

  List<String> ids() => [
    for (final m in c.read(messagesProvider).value ?? const <Message>[]) m.id,
  ];

  /// Every value messagesProvider takes from now on, for the "never the
  /// previous chat's" check. Records the ids together with the open chat.
  List<(String?, List<Message>?)> record() {
    final seen = <(String?, List<Message>?)>[];
    c.listen(
      messagesProvider,
      (_, next) => seen.add((c.read(openConversationProvider), next.value)),
      fireImmediately: true,
    );
    return seen;
  }

  void onlyFrom(
    List<(String?, List<Message>?)> seen,
    String conv, {
    int from = 0,
  }) {
    for (final (_, value) in seen.sublist(from)) {
      for (final m in value ?? const <Message>[]) {
        expect(
          m.conversationId,
          conv,
          reason:
              'state showed ${m.id} of ${m.conversationId} while $conv was open',
        );
      }
    }
  }

  Future<void> open(String id) async {
    c.read(openConversationProvider.notifier).open(id);
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
    await settle();
  }

  group('switching chats', () {
    test("What's new, then another chat at once, before any refresh: only "
        "the second chat's rows, never What's new's", () async {
      final seen = record();
      await open('sis');
      expect(ids(), ['w1', 'w2']);
      chat.holdRead('a');
      final mark = seen.length;
      c.read(openConversationProvider.notifier).open('a');
      await settle();
      onlyFrom(seen, 'a', from: mark);
      expect(ids(), isEmpty, reason: "A is loading: nothing of What's new's");
      chat.releaseRead('a');
      await eventually(() => ids().isNotEmpty, reason: 'A never loaded');
      await settle();
      expect(ids(), ['a1', 'a2']);
      onlyFrom(seen, 'a', from: mark);
    });

    test("A loaded, then B: while B loads the value is empty or absent, "
        "never A's; then B's rows only", () async {
      final seen = record();
      await open('a');
      expect(ids(), ['a1', 'a2']);
      chat.holdRead('b');
      final mark = seen.length;
      c.read(openConversationProvider.notifier).open('b');
      await settle();
      onlyFrom(seen, 'b', from: mark);
      expect(ids(), isEmpty, reason: "B is loading: nothing of A's");
      chat.releaseRead('b');
      await eventually(() => ids().isNotEmpty, reason: 'B never loaded');
      await settle();
      expect(ids(), ['b1']);
      onlyFrom(seen, 'b', from: mark);
    });

    test('A -> null -> B in one go: B shows only its own rows', () async {
      final seen = record();
      await open('a');
      chat.holdRead('b');
      final mark = seen.length;
      // Closed and another opened in the same frame: no rebuild ran for null.
      c.read(openConversationProvider.notifier).close();
      c.read(openConversationProvider.notifier).open('b');
      await settle();
      onlyFrom(seen, 'b', from: mark);
      chat.releaseRead('b');
      await eventually(() => ids().isNotEmpty);
      await settle();
      expect(ids(), ['b1']);
      onlyFrom(seen, 'b', from: mark);
    });

    test("A Realtime row for A arriving after the switch to B is dropped, "
        "while B loads and after", () async {
      final seen = record();
      await open('a');
      chat.holdRead('b');
      final mark = seen.length;
      c.read(openConversationProvider.notifier).open('b');
      await settle();
      chat.deliver(msg('late-a1', 'a', minute: 5));
      chat.leak('a', msg('late-a2', 'a', minute: 6));
      await settle();
      chat.releaseRead('b');
      await eventually(() => ids().isNotEmpty);
      chat.confirmSubscription();
      await settle();
      chat.deliver(msg('late-a3', 'a', minute: 7));
      chat.leak('a', msg('late-a4', 'a', minute: 8));
      await settle();
      expect(ids(), ['b1']);
      onlyFrom(seen, 'b', from: mark);
    });
  });

  group("rows from another conversation on B's subscription", () {
    test('a live row with a different conversationId is ignored; '
        "B's own still arrives", () async {
      await open('b');
      chat.leak('b', msg('foreign', 'a', minute: 3));
      chat.deliver(msg('b2', 'b', minute: 4));
      await eventually(() => ids().contains('b2'), reason: 'B lost its own');
      await settle();
      expect(ids(), ['b1', 'b2']);
    });

    test("buffered while B's first read is in flight: the foreign row is "
        "not merged, B's own is", () async {
      chat.holdRead('b');
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('b');
      await eventually(() => chat.calls.contains('incoming:b'));
      await settle();
      chat.leak('b', msg('foreign', 'a', minute: 3));
      chat.leak('b', msg('b2', 'b', minute: 4));
      await settle();
      chat.releaseRead('b');
      await eventually(() => ids().isNotEmpty);
      await settle();
      expect(ids(), ['b1', 'b2']);
    });
  });

  test('a same-chat catchUp keeps the shown list while it reloads', () async {
    final seen = record();
    await open('a');
    final mark = seen.length;
    chat.holdRead('a');
    c.read(messagesProvider.notifier).catchUp();
    await settle();
    for (final (_, value) in seen.sublist(mark)) {
      expect(value?.map((m) => m.id), [
        'a1',
        'a2',
      ], reason: 'the list blanked or changed while the same chat reloaded');
    }
    chat.history['a']!.add(msg('a3', 'a', minute: 9));
    chat.releaseRead('a');
    await eventually(() => ids().contains('a3'), reason: 'catchUp never read');
    expect(ids(), ['a1', 'a2', 'a3']);
  });

  group('the screen', () {
    Future<void> step(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<ProviderContainer> mount(WidgetTester tester, String open) async {
      final container = await settled(
        ProviderContainer.test(
          overrides: [
            chatRepositoryProvider.overrideWithValue(chat),
            presenceRepositoryProvider.overrideWithValue(PresenceFake()),
            sessionControllerProvider.overrideWith(_In.new),
            pushSourceProvider.overrideWithValue(PushSourceFake()),
            pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          ],
        ),
      );
      container.read(openConversationProvider.notifier).open(open);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: MessageScreen()),
        ),
      );
      await step(tester);
      return container;
    }

    Finder bubble(String id) => find.byKey(ValueKey('message-$id'));

    testWidgets("switching A -> B shows none of A's bubbles while B loads, "
        "then B's", (tester) async {
      final container = await mount(tester, 'a');
      chat.confirmSubscription();
      await step(tester);
      expect(bubble('a1'), findsOneWidget);

      chat.holdRead('b');
      container.read(openConversationProvider.notifier).open('b');
      await step(tester);
      expect(bubble('a1'), findsNothing, reason: "A's rows shown as B's");
      expect(bubble('a2'), findsNothing);

      chat.releaseRead('b');
      await step(tester);
      expect(bubble('b1'), findsOneWidget);
      expect(bubble('a1'), findsNothing);

      // A row of A's on B's subscription never becomes a bubble.
      chat.leak('b', msg('foreign', 'a', minute: 5));
      await step(tester);
      expect(bubble('foreign'), findsNothing);
    });
  });

  group('openConversation leaving while markRead is slow', () {
    late BuildContext ctx;
    late WidgetRef wref;

    Future<ProviderContainer> mount(WidgetTester tester) async {
      final container = await settled(
        ProviderContainer.test(
          overrides: [
            chatRepositoryProvider.overrideWithValue(chat),
            presenceRepositoryProvider.overrideWithValue(PresenceFake()),
            sessionControllerProvider.overrideWith(_In.new),
            pushSourceProvider.overrideWithValue(PushSourceFake()),
            pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          ],
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ctx = context;
                wref = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return container;
    }

    Future<void> step(WidgetTester tester) async {
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    void pop(WidgetTester tester) =>
        tester.state<NavigatorState>(find.byType(Navigator)).pop();

    testWidgets('opened from the list: B opened meanwhile stays open, '
        'not closed', (tester) async {
      final container = await mount(tester);
      unawaited(openConversation(ctx, wref, 'a', title: 'A'));
      await step(tester);
      expect(container.read(openConversationProvider), 'a');

      chat.holdMarkRead();
      pop(tester);
      await step(tester);
      unawaited(openConversation(ctx, wref, 'b', title: 'B'));
      await step(tester);
      expect(container.read(openConversationProvider), 'b');

      chat.releaseMarkRead();
      await step(tester);
      expect(
        container.read(openConversationProvider),
        'b',
        reason: "A's late leave closed the chat the member had opened since",
      );
    });

    testWidgets('opened from inside X: B opened meanwhile stays open, '
        'not restored to X', (tester) async {
      final container = await mount(tester);
      unawaited(openConversation(ctx, wref, 'sis', title: 'SIS'));
      await step(tester);
      unawaited(openConversation(ctx, wref, 'a', title: 'A'));
      await step(tester);
      expect(container.read(openConversationProvider), 'a');

      chat.holdMarkRead();
      pop(tester);
      await step(tester);
      unawaited(openConversation(ctx, wref, 'b', title: 'B'));
      await step(tester);

      chat.releaseMarkRead();
      await step(tester);
      expect(
        container.read(openConversationProvider),
        'b',
        reason: "A's late leave restored X over the chat opened since",
      );
    });

    testWidgets('control: leaving A with nothing opened since restores X', (
      tester,
    ) async {
      final container = await mount(tester);
      unawaited(openConversation(ctx, wref, 'sis', title: 'SIS'));
      await step(tester);
      unawaited(openConversation(ctx, wref, 'a', title: 'A'));
      await step(tester);
      chat.holdMarkRead();
      pop(tester);
      await step(tester);
      chat.releaseMarkRead();
      await step(tester);
      expect(container.read(openConversationProvider), 'sis');
    });
  });
}

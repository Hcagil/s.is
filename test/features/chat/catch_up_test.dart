// Catching up after the app was in the background, from the contract:
//
// - ConversationListController.catchUp(): a no-op while loading; otherwise
//   re-read, drop the old Realtime subscription, join again, re-read. A join
//   that lands after a newer catchUp is cancelled and not applied. A join
//   that fails still leaves the list re-read.
// - MessagesController.catchUp(): a no-op while loading or while a search
//   jump is shown; otherwise the open chat is read again, joining first.
// - resumeCatchUpProvider: nothing unless the session is Allowed; clears the
//   open chat's notification and catches both up.
//
// The defect (0.25.1, owner): after the phone had been in the background the
// socket was dead, nothing re-joined or re-read, and a chat opened from a
// notification lacked the new messages until closed and reopened. ChatFake
// models the dead socket with loseRealtime(): old subscriptions stay open and
// never deliver again, exactly as a channel whose socket the OS closed.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const maya = Member(userId: 'u1', displayName: 'Maya');
final _t0 = DateTime.utc(2026, 9, 29, 12);

Message msg(String id, int minute, {String conv = 'c1', String from = 'u2'}) =>
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

class _Out extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
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
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late ChatFake chat;
  late PushSourceFake push;
  late ProviderContainer c;

  ProviderContainer make({bool allowed = true}) => ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      pushSourceProvider.overrideWithValue(push),
      sessionControllerProvider.overrideWith(allowed ? _In.new : _Out.new),
    ],
  );

  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  MessagesController messages() => c.read(messagesProvider.notifier);
  ConversationListController list() =>
      c.read(conversationListProvider.notifier);
  Conversation row(String id) => c
      .read(conversationListProvider)
      .requireValue
      .singleWhere((r) => r.id == id);
  int count(String call, [int from = 0]) =>
      chat.calls.sublist(from).where((x) => x == call).length;

  /// The list's catch-up (read, join, read again) has run to its end, so
  /// the test does not dispose the container underneath it.
  Future<void> finished(int mark) async {
    await eventually(() => count('conversations', mark) >= 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  setUp(() {
    chat = ChatFake(self: 'u1', latency: const Duration(milliseconds: 2));
    push = PushSourceFake();
    chat.history['c1'] = [msg('m1', 1)];
    chat.conversationsResult = Ok([
      Conversation(
        id: 'c1',
        title: 'Bob',
        lastMessage: 'body m1',
        lastMessageAt: _t0.add(const Duration(minutes: 1)),
        lastSenderId: 'u2',
      ),
      Conversation(
        id: 'c2',
        title: 'Cy',
        lastMessage: 'older',
        lastMessageAt: _t0,
        lastSenderId: 'u3',
      ),
    ]);
  });

  /// Opens c1 and lets the open run to its end: the join, the read and the
  /// background verify re-read (0.30.12), so a gap made afterwards is real.
  Future<void> openC1() async {
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
    await eventually(() => count('messages:c1') >= 2, reason: 'verify read');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> loadList() async {
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    chat.confirmAllSubscription();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  group('MessagesController.catchUp', () {
    setUp(() async {
      c = make();
      await c.read(sessionControllerProvider.future);
    });

    test('a message sent while the socket was dead appears, and the next one '
        'arrives live', () async {
      await openC1();
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        shown(),
        ['m1'],
        reason:
            'the gap must be real, or this proves '
            'nothing',
      );

      messages().catchUp();
      await eventually(
        () => shown().contains('m2'),
        reason: 'm2 after catchUp',
      );
      expect(shown(), ['m1', 'm2']);

      chat.deliver(msg('m3', 3));
      await eventually(
        () => shown().contains('m3'),
        reason: 'catchUp must join again, not only re-read',
      );
    });

    // 0.30.12: the join and the read run together; a read made once the
    // join is confirmed is what leaves nothing between the two.
    test('joins again and reads once the join is confirmed, so nothing falls '
        'between the two', () async {
      await openC1();
      final mark = chat.calls.length;
      chat.holdSubscription();

      messages().catchUp();
      await eventually(() => count('incoming:c1', mark) == 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final confirmed = chat.calls.length;
      chat.confirmSubscription();

      await eventually(
        () => count('messages:c1', confirmed) >= 1,
        reason: 'no read after the join was confirmed: ${chat.calls}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    test('while the chat is still loading: a no-op', () async {
      chat.holdMessages();
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await eventually(() => count('messages:c1') == 1);
      expect(c.read(messagesProvider).isLoading, isTrue);

      messages().catchUp();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      chat.releaseMessages();
      await c.read(messagesProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // The open's own read and its verify re-read; catchUp added nothing.
      expect(count('messages:c1'), 2, reason: '${chat.calls}');
      expect(count('incoming:c1'), 1, reason: '${chat.calls}');
    });

    test(
      'while a search jump is shown: a no-op, the jumped window stays',
      () async {
        chat.history['c1'] = [for (var i = 0; i < 600; i++) msg('h$i', i)];
        await openC1();
        await messages().jumpToAround(chat.history['c1']![30]);
        final jumped = shown();
        expect(jumped, contains('h30'));
        final mark = chat.calls.length;

        messages().catchUp();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(shown(), jumped);
        expect(count('messages:c1', mark), 0, reason: '${chat.calls}');
        expect(count('incoming:c1', mark), 0, reason: '${chat.calls}');
      },
    );
  });

  group('ConversationListController.catchUp', () {
    setUp(() async {
      c = make();
      await c.read(sessionControllerProvider.future);
    });

    test('a message sent while the socket was dead shows on the list, and '
        'the next one arrives live', () async {
      await loadList();
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(row('c1').lastMessage, 'body m1', reason: 'the gap is real');

      await list().catchUp();
      expect(row('c1').lastMessage, 'body m2');

      chat.deliver(msg('m3', 3));
      await eventually(
        () => row('c1').lastMessage == 'body m3',
        reason: 'catchUp must join again',
      );
      expect(chat.liveAllListeners, 1, reason: 'the dead join is cancelled');
    });

    test('while the list is still loading: a no-op', () async {
      chat.holdList();
      c.listen(conversationListProvider, (_, _) {});
      await eventually(() => count('conversations') == 1);

      final pending = list().catchUp();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      chat.releaseList();
      await pending;
      await c.read(conversationListProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(count('conversations'), 1, reason: '${chat.calls}');
      expect(count('incomingAll'), 1, reason: '${chat.calls}');
    });

    test('a join that lands after a newer catchUp is cancelled and not '
        'applied', () async {
      await loadList();
      chat.holdAllSubscription();
      final mark = chat.calls.length;

      final first = list().catchUp();
      await eventually(() => count('incomingAll', mark) == 1);
      final second = list().catchUp();
      await eventually(() => count('incomingAll', mark) == 2);
      chat.confirmAllSubscription();
      await Future.wait([first, second]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(chat.liveAllListeners, 1, reason: 'one live join, not two');
      final before = row('c1').unread;
      chat.deliver(msg('m9', 9));
      await eventually(() => row('c1').lastMessage == 'body m9');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(row('c1').unread, before + 1, reason: 'applied once');
    });

    test('a join that fails still leaves the list re-read', () async {
      await loadList();
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      chat.incomingAllResult = const Err(NetworkFailure('realtime down'));

      await list().catchUp();

      expect(c.read(conversationListProvider).hasValue, isTrue);
      expect(row('c1').lastMessage, 'body m2');
    });
  });

  group('resumeCatchUpProvider', () {
    test('signed out: nothing is read, joined or cleared', () async {
      c = make(allowed: false);
      await c.read(sessionControllerProvider.future);
      c.read(openConversationProvider.notifier).open('c1');
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(chat.calls.sublist(mark), isEmpty);
      expect(push.cleared, isEmpty);
    });

    test('allowed, a chat open: its notification is cleared and both the '
        'chat and the list catch up', () async {
      c = make();
      await c.read(sessionControllerProvider.future);
      await loadList();
      await openC1();
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(shown(), ['m1']);
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();

      await eventually(() => shown().contains('m2'), reason: 'the chat');
      await eventually(
        () => row('c1').lastMessage == 'body m2',
        reason: 'the list',
      );
      expect(push.cleared, ['c1']);
      await finished(mark);
    });

    test('allowed, no chat open: nothing to clear, the list still catches '
        'up', () async {
      c = make();
      await c.read(sessionControllerProvider.future);
      await loadList();
      chat.loseRealtime();
      chat.deliver(msg('m2', 2));
      final mark = chat.calls.length;

      c.read(resumeCatchUpProvider)();

      await eventually(() => row('c1').lastMessage == 'body m2');
      expect(push.cleared, isEmpty);
      await finished(mark);
    });

    test(
      'the list rebuilt (e.g. an account switch) while a resume catch-up '
      'is still reading: no error, and the stale read is not applied',
      () async {
        c = make();
        await c.read(sessionControllerProvider.future);
        await loadList();
        chat.holdList();
        final mark = chat.calls.length;

        c.read(resumeCatchUpProvider)();
        await eventually(() => count('conversations', mark) == 1);
        c.invalidate(conversationListProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        chat.releaseList();
        await c.read(conversationListProvider.future);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(c.read(conversationListProvider).hasValue, isTrue);
        expect(chat.liveAllListeners, 1, reason: 'one live join');
      },
    );
  });
}

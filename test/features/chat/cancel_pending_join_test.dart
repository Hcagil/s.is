// cancelPendingJoinProvider, from the contract (t_50655c1325 fix round 2b):
// closing, switching away from, or disposing the open chat while its join is
// unanswered calls it once with that conversation id; never when the join
// had already answered. ChatFake holds the join until the test confirms it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'me', displayName: 'Maya');

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

final _t0 = DateTime.utc(2026, 1, 1);

List<Message> _rows(String conv) => [
  for (var i = 0; i < 5; i++)
    Message(
      id: '$conv-$i',
      conversationId: conv,
      senderId: 'bob',
      body: 'body $i',
      createdAt: _t0.add(Duration(minutes: i)),
    ),
];

void main() {
  late ChatFake chat;
  late ProviderContainer c;
  late List<String> cancelled;
  var made = false;

  Future<void> elapse(WidgetTester t, Duration d) async {
    const step = Duration(milliseconds: 100);
    for (var left = d; left > Duration.zero; left -= step) {
      await t.pump(left < step ? left : step);
    }
  }

  Future<void> open(WidgetTester t, String id) async {
    if (!made) {
      made = true;
      c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          sessionControllerProvider.overrideWith(_In.new),
          cancelPendingJoinProvider.overrideWithValue(cancelled.add),
        ],
      );
      c.listen(messagesProvider, (_, _) {});
      await elapse(t, const Duration(milliseconds: 100));
    }
    c.read(openConversationProvider.notifier).open(id);
    await elapse(t, const Duration(milliseconds: 500));
    expect(c.read(messagesProvider).hasValue, isTrue, reason: 'fixture');
  }

  setUp(() {
    cancelled = [];
    made = false;
    chat = ChatFake();
    chat.history['c1'] = _rows('c1');
    chat.history['c2'] = _rows('c2');
  });

  testWidgets('closing the chat with its join out cancels it once', (t) async {
    chat.holdSubscription();
    await open(t, 'c1');
    expect(cancelled, isEmpty, reason: 'not while it is open');
    c.read(openConversationProvider.notifier).close();
    await elapse(t, const Duration(milliseconds: 300));
    expect(cancelled, ['c1']);
    c.dispose();
    expect(cancelled, ['c1'], reason: 'once');
    chat.confirmSubscription();
    await elapse(t, const Duration(milliseconds: 300));
  });

  testWidgets('opening another chat while the join is out cancels the old '
      'one', (t) async {
    await open(t, 'c1');
    expect(chat.subscriptions, 1, reason: "fixture: c1's join answered");
    chat.holdSubscription(); // c2's join stays out
    await open(t, 'c2');
    expect(cancelled, isEmpty, reason: 'c1 had joined: nothing to cancel');
    c.read(openConversationProvider.notifier).open('c1');
    await elapse(t, const Duration(milliseconds: 300));
    expect(cancelled, ['c2'], reason: 'c2 was left with its join out');
    c.dispose();
    chat.confirmSubscription();
    await elapse(t, const Duration(milliseconds: 300));
  });

  testWidgets('disposing the app with the join out cancels it', (t) async {
    chat.holdSubscription();
    await open(t, 'c1');
    c.dispose();
    expect(cancelled, ['c1']);
    chat.confirmSubscription();
    await elapse(t, const Duration(milliseconds: 300));
  });

  testWidgets('a join that already answered is not cancelled', (t) async {
    await open(t, 'c1');
    expect(chat.subscriptions, greaterThan(0), reason: 'fixture: joined');
    c.read(openConversationProvider.notifier).close();
    await elapse(t, const Duration(milliseconds: 300));
    await open(t, 'c2');
    c.dispose();
    expect(cancelled, isEmpty);
  });
}

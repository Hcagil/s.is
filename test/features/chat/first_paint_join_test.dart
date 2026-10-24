// Opening a chat while the Realtime join is slow, from the contract (fix
// "new messages appear at once", t_50655c1325, part D):
// - the server read alone decides the first paint; a join still unanswered
//   does not hold it (the defect: a cold start from a notification waited
//   for a join that can take 15 s, then a 5 s retry);
// - a join that answers later and succeeds: one immediate re-read, merged by
//   id (no duplicate bubbles);
// - a join that answers later with an error: up to 5 retries, 5 s apart;
//   a refusal (Denied) is not retried;
// - a failed read keeps the old path (an error with nothing stored);
// - a join that had already failed when the read arrives: the old path.
// ChatFake never confirms a join until the test does (holdSubscription), so
// "slow join" is modelled exactly; fake time (testWidgets) for the 5 s steps.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
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

Message _m(String id, int minute) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'bob',
  body: 'body $id',
  createdAt: _t0.add(Duration(minutes: minute)),
);

const _offline = NetworkFailure('offline', retryable: true);

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  AsyncValue<List<Message>> state() => c.read(messagesProvider);
  List<String> shown() => state().requireValue.map((m) => m.id).toList();
  int reads() => chat.calls.where((x) => x == 'messages:c1').length;
  int joins() => chat.calls.where((x) => x == 'incoming:c1').length;

  Future<void> elapse(WidgetTester t, Duration d) async {
    const step = Duration(milliseconds: 100);
    for (var left = d; left > Duration.zero; left -= step) {
      await t.pump(left < step ? left : step);
    }
  }

  /// Opens c1 with 60 rows on the server and lets [d] of fake time pass.
  Future<void> open(
    WidgetTester t, {
    Duration d = const Duration(seconds: 1),
  }) async {
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        sessionControllerProvider.overrideWith(_In.new),
      ],
    );
    addTearDown(c.dispose);
    c.listen(messagesProvider, (_, _) {});
    await elapse(t, const Duration(milliseconds: 100));
    c.read(openConversationProvider.notifier).open('c1');
    await elapse(t, d);
  }

  setUp(() {
    chat = ChatFake();
    chat.history['c1'] = [for (var i = 0; i < 60; i++) _m('c1-$i', i)];
  });

  testWidgets('first paint comes from the read while the join is unanswered', (
    t,
  ) async {
    chat.holdSubscription();
    await open(t, d: const Duration(milliseconds: 500));
    expect(chat.subscriptions, 0, reason: 'fixture: the join is unanswered');
    expect(state().hasValue, isTrue, reason: 'painted without the join');
    expect(state().isLoading, isFalse);
    expect(shown().last, 'c1-59');
    chat.confirmSubscription();
    await elapse(t, const Duration(seconds: 1));
  });

  testWidgets('a join that succeeds later: one immediate re-read brings in '
      'what was missed, no duplicates', (t) async {
    chat.holdSubscription();
    await open(t);
    // Written after the read, before the join: Realtime will never deliver it.
    chat.deliver(_m('gap', 61));
    expect(shown(), isNot(contains('gap')), reason: 'fixture: the gap is real');
    final mark = reads();
    chat.confirmSubscription();
    await elapse(t, const Duration(milliseconds: 300));
    expect(shown().last, 'gap', reason: 're-read at once after the join');
    expect(reads(), mark + 1, reason: 'exactly one re-read');
    expect(shown().toSet().length, shown().length, reason: 'merged by id');
    await elapse(t, const Duration(seconds: 30));
    expect(reads(), mark + 1, reason: 'no further re-reads');
    // And the joined subscription is live.
    chat.deliver(_m('live', 62));
    await elapse(t, const Duration(milliseconds: 300));
    expect(shown().last, 'live');
    expect(shown().where((id) => id == 'gap').length, 1);
  });

  testWidgets('a join that fails later: retried up to 5 times, 5 s apart', (
    t,
  ) async {
    chat.holdSubscription();
    await open(t);
    chat.incomingResult = const Err(_offline);
    final before = joins();
    chat.confirmSubscription();
    await elapse(t, const Duration(milliseconds: 100));
    final failedAt = joins();
    expect(failedAt, before, reason: 'fixture: the held join answered');
    // Sample every 100 ms of fake time and record when each retry joins.
    final times = <int>[];
    var seen = failedAt;
    for (var ms = 0; ms < 60000; ms += 100) {
      await t.pump(const Duration(milliseconds: 100));
      if (joins() > seen) {
        seen = joins();
        times.add(ms);
      }
    }
    expect(times, hasLength(5), reason: 'up to 5 retries: $times');
    expect(times.first, greaterThanOrEqualTo(4500), reason: 'first after 5 s');
    for (var i = 1; i < times.length; i++) {
      expect(
        times[i] - times[i - 1],
        inInclusiveRange(4500, 5600),
        reason: '5 s apart: $times',
      );
    }
    expect(shown(), contains('c1-59'), reason: 'the painted list is kept');
  });

  testWidgets('Realtime down, reads fine: every join times out (15 s) after '
      'the paint; still at most 5 retries', (t) async {
    chat.holdSubscription();
    await open(t);
    chat.incomingResult = const Err(_offline);
    final first = joins();
    // Each join is answered with an error 15 s after it was made, as
    // joinChannel's timeout does when Realtime never answers; the next join
    // is held again.
    var pendingSince = 0;
    var seen = joins();
    for (var ms = 0; ms < 240000; ms += 100) {
      if (joins() > seen) {
        seen = joins();
        pendingSince = ms;
      }
      if (ms - pendingSince >= 15000) {
        chat.confirmSubscription();
        chat.holdSubscription();
        pendingSince = 1 << 30; // answered; wait for the next join
      }
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(
      joins() - first,
      inInclusiveRange(1, 5),
      reason: 'up to 5 retries in 4 minutes',
    );
    chat.confirmSubscription();
    await elapse(t, const Duration(seconds: 1));
  });

  testWidgets('after the 5th failed late join: the read list stays, no '
      'error, nothing more is asked', (t) async {
    chat.holdSubscription();
    await open(t);
    chat.incomingResult = const Err(_offline);
    // Every join fails 100 ms after it is made; the next one is held again.
    for (var ms = 0; ms < 60000; ms += 100) {
      chat.confirmSubscription();
      chat.holdSubscription();
      await t.pump(const Duration(milliseconds: 100));
    }
    chat.confirmSubscription();
    await elapse(t, const Duration(seconds: 1));
    expect(state().hasError, isFalse, reason: 'no full-screen error');
    expect(state().hasValue, isTrue);
    expect(shown().last, 'c1-59', reason: 'the read list stays');
    final (j, r) = (joins(), reads());
    await elapse(t, const Duration(seconds: 60));
    expect((joins(), reads()), (j, r), reason: 'nothing more after the 5th');
    expect(state().hasError, isFalse);
    expect(shown().last, 'c1-59');
  });

  testWidgets('a join refused later (Denied) is not retried', (t) async {
    chat.holdSubscription();
    await open(t);
    chat.incomingResult = const Err(DeniedFailure());
    chat.confirmSubscription();
    await elapse(t, const Duration(milliseconds: 300));
    final after = joins();
    await elapse(t, const Duration(seconds: 40));
    expect(joins(), after, reason: 'a refusal is never retried');
  });

  testWidgets('a failed read with nothing stored is an error', (t) async {
    chat.history.remove('c1');
    chat.messagesResult = const Err(DeniedFailure());
    await open(t);
    expect(state().hasError, isTrue);
  });

  testWidgets('a failed read while the join is unanswered is an error', (
    t,
  ) async {
    chat.history.remove('c1');
    chat.messagesResult = const Err(DeniedFailure());
    chat.holdSubscription();
    await open(t);
    expect(state().hasError, isTrue, reason: 'shown without the join');
    chat.confirmSubscription();
    await elapse(t, const Duration(seconds: 1));
    expect(state().hasError, isTrue);
  });

  testWidgets('the join already failed when the read arrives: old path', (
    t,
  ) async {
    chat.incomingResult = const Err(_offline);
    chat.holdMessages();
    await open(t, d: const Duration(milliseconds: 300));
    chat.releaseMessages();
    await elapse(t, const Duration(milliseconds: 300));
    // The old path, as on main 422bf75 for the same scenario: an error
    // (nothing stored), and no retry of its own.
    expect(state().hasError, isTrue);
    expect((joins(), reads()), (1, 1));
    chat.incomingResult = null;
    await elapse(t, const Duration(seconds: 36));
    expect(state().hasError, isTrue);
    expect((joins(), reads()), (1, 1), reason: 'no retry');
  });
}

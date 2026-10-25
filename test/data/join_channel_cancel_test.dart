// joinChannel(channel, {timeout, onRejoin, cancelled}), from the contract
// (t_50655c1325 fix round 2b):
// - `cancelled` completing before `subscribed`: the join fails at once with
//   JoinCancelled and leaves no timer pending;
// - completing after the join answered: no effect;
// - without `cancelled`: unchanged (subscribed completes; silence times out).
// The channel is a stand-in that only records the subscribe callback, so the
// test decides when (and whether) the server answers. testWidgets fails a
// test that ends with a Timer still pending: that is the "no timer" check.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/realtime_channels.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Channel extends Fake implements RealtimeChannel {
  void Function(RealtimeSubscribeStatus status, Object? error)? answer;

  @override
  RealtimeChannel subscribe([
    void Function(RealtimeSubscribeStatus status, Object? error)? callback,
    Duration? timeout,
  ]) {
    answer = callback;
    return this;
  }
}

void main() {
  const timeout = Duration(seconds: 15);

  testWidgets('cancelled before subscribed: JoinCancelled at once, no timer '
      'left', (t) async {
    final ch = _Channel();
    final cancel = Completer<void>();
    Object? error;
    var done = false;
    joinChannel(ch, timeout: timeout, cancelled: cancel.future).then<void>(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
    await t.pump();
    expect(ch.answer, isNotNull, reason: 'fixture: subscribe was called');
    expect(done, isFalse, reason: 'fixture: the join is out');
    cancel.complete();
    await t.pump();
    expect(done, isTrue, reason: 'ends at once, not at the timeout');
    expect(error, isA<JoinCancelled>());
    // A late server confirm changes nothing.
    ch.answer!(RealtimeSubscribeStatus.subscribed, null);
    await t.pump();
    expect(error, isA<JoinCancelled>());
    // The test ends here: a pending 15 s timer would fail it.
  });

  testWidgets('cancelled after the join answered: no effect', (t) async {
    final ch = _Channel();
    final cancel = Completer<void>();
    Object? error;
    var ok = false;
    joinChannel(ch, timeout: timeout, cancelled: cancel.future).then<void>(
      (_) => ok = true,
      onError: (Object e) {
        error = e;
      },
    );
    await t.pump();
    ch.answer!(RealtimeSubscribeStatus.subscribed, null);
    await t.pump();
    expect(ok, isTrue, reason: 'fixture: joined');
    cancel.complete();
    await t.pump(const Duration(seconds: 20));
    expect(error, isNull);
    expect(ok, isTrue);
  });

  testWidgets('cancelled after the join failed: the original error stays', (
    t,
  ) async {
    final ch = _Channel();
    final cancel = Completer<void>();
    Object? error;
    joinChannel(ch, timeout: timeout, cancelled: cancel.future).then<void>(
      (_) {},
      onError: (Object e) {
        error = e;
      },
    );
    await t.pump();
    ch.answer!(RealtimeSubscribeStatus.channelError, 'refused');
    await t.pump();
    expect(error, isNotNull, reason: 'fixture: failed');
    expect(error, isNot(isA<JoinCancelled>()));
    final first = error;
    cancel.complete();
    await t.pump(const Duration(seconds: 20));
    expect(error, same(first));
  });

  testWidgets('without cancelled: subscribed completes it', (t) async {
    final ch = _Channel();
    var ok = false;
    joinChannel(ch, timeout: timeout).then<void>((_) => ok = true);
    await t.pump();
    ch.answer!(RealtimeSubscribeStatus.subscribed, null);
    await t.pump();
    expect(ok, isTrue);
  });

  testWidgets('without cancelled: silence fails at the timeout, not before', (
    t,
  ) async {
    final ch = _Channel();
    Object? error;
    joinChannel(ch, timeout: timeout).then<void>(
      (_) {},
      onError: (Object e) {
        error = e;
      },
    );
    await t.pump(const Duration(seconds: 14));
    expect(error, isNull);
    await t.pump(const Duration(seconds: 2));
    expect(error, isA<TimeoutException>());
  });
}

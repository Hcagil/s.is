// Delivery marks (Update 1 slice 5) on top of [ChatFake], derived from the
// ChatRepository contract and the mark_delivered / delivered:<conv> server
// contract (20261005150000), not from the client code:
//  * markDelivered is fire-and-forget for its caller, and may be slow or fail;
//    every call is recorded with its upTo.
//  * deliveredUpdates is joined before it resolves (it can be held, like a
//    subscription the server has not confirmed yet), keeps what arrives until
//    listened to, and drops anything sent before the join -- Realtime manners.
//    Its events carry only userId and deliveredAt (shares false).
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/read_marks.dart';

import 'fakes.dart';

class DeliveryChat extends ChatFake {
  DeliveryChat({super.latency, super.self});

  /// Every markDelivered call, in order: (conversation, upTo).
  final delivered = <(String, DateTime?)>[];

  /// What markDelivered answers; Ok unless forced.
  Result<void> markDeliveredResult = const Ok(null);

  Completer<void>? _markHold;

  /// markDelivered calls stay in flight until [releaseMarkDelivered].
  void holdMarkDelivered() => _markHold = Completer<void>();
  void releaseMarkDelivered() {
    _markHold?.complete();
    _markHold = null;
  }

  @override
  Future<Result<void>> markDelivered(
    String conversationId, {
    DateTime? upTo,
  }) async {
    delivered.add((conversationId, upTo));
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final held = _markHold;
    if (held != null) await held.future;
    return markDeliveredResult;
  }

  /// When set, deliveredUpdates reports a subscription that could not be made.
  Result<Stream<ReadMark>>? deliveredUpdatesResult;
  final _sinks = <String, List<StreamController<ReadMark>>>{};
  int deliveredSubscriptions = 0;
  int canceledDeliveredSubscriptions = 0;
  Completer<void>? _subscribe;

  /// Delivery channels joined and not left. Like the real repository, a
  /// channel is left only when its stream's listener cancels: a stream
  /// never listened to keeps its channel joined.
  int get joinedDeliveryChannels =>
      _sinks.values.fold(0, (n, sinks) => n + sinks.length);

  /// deliveredUpdates (the join) stays unanswered until
  /// [confirmDeliveredSubscription].
  void holdDeliveredSubscription() => _subscribe = Completer<void>();
  void confirmDeliveredSubscription() {
    _subscribe?.complete();
    _subscribe = null;
  }

  /// A delivery event as the server broadcasts it: user and position only.
  void deliverDelivery(String conversationId, String userId, DateTime at) {
    final mark = ReadMark(userId: userId, shares: false, deliveredAt: at);
    for (final sink in [...?_sinks[conversationId]]) {
      sink.add(mark);
    }
  }

  @override
  Future<Result<Stream<ReadMark>>> deliveredUpdates(
    String conversationId,
  ) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final held = _subscribe;
    if (held != null) await held.future;
    if (deliveredUpdatesResult case final failed?) return failed;
    deliveredSubscriptions++;
    late final StreamController<ReadMark> sink;
    sink = StreamController<ReadMark>(
      onCancel: () {
        canceledDeliveredSubscriptions++;
        _sinks[conversationId]?.remove(sink);
      },
    );
    (_sinks[conversationId] ??= []).add(sink);
    return Ok(sink.stream);
  }
}

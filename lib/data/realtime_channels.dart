import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Joining and leaving Realtime channels, shared by every repository that
/// uses one. Both halves exist because the wrong version was written twice:
/// a teardown awaited on a failure path hangs the path meant to stop the
/// screen hanging.

/// The join was ended by its caller (the screen closed first): not a failure.
class JoinCancelled implements Exception {
  const JoinCancelled();
}

/// Subscribes [channel] and completes once the server confirms the join.
///
/// Fails on `channelError`, `timedOut`, any reported error, or after
/// [timeout] -- a refused private channel and an unreachable server both end
/// here instead of hanging.
/// [onRejoin] runs each time the channel confirms a join AFTER the first (a reconnect).
/// [cancelled] completing ends a join still out at once: the timeout timer is cancelled and the result fails with [JoinCancelled].
Future<void> joinChannel(
  RealtimeChannel channel, {
  Duration timeout = const Duration(seconds: 15),
  void Function()? onRejoin,
  Future<void>? cancelled,
}) {
  final joined = Completer<void>();
  channel.subscribe((status, error) {
    if (joined.isCompleted) {
      // The client re-joins the channel by itself after a dropped socket: tell the caller, which must catch up on what it missed.
      if (status == RealtimeSubscribeStatus.subscribed) onRejoin?.call();
      return;
    }
    if (status == RealtimeSubscribeStatus.subscribed) {
      joined.complete();
    } else if (status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.timedOut ||
        error != null) {
      joined.completeError(error ?? status);
    }
  });
  if (cancelled != null) {
    unawaited(
      cancelled.then((_) {
        if (!joined.isCompleted) joined.completeError(const JoinCancelled());
      }),
    );
  }
  return joined.future.timeout(timeout);
}

/// Leaves [channel] and closes [controller] without waiting for either.
///
/// Never await these: on a dead socket removeChannel waits for an
/// unsubscribe reply that never arrives, and close() on a stream nobody ever
/// listened to completes only once someone does. Never throws either: it runs
/// on failure paths, and close() throws synchronously mid-addStream.
void leaveChannel(
  SupabaseClient client,
  RealtimeChannel channel, [
  StreamController<Object?>? controller,
]) {
  try {
    if (controller != null) unawaited(controller.close().catchError((_) {}));
  } catch (_) {}
  try {
    unawaited(client.removeChannel(channel).catchError((_) => ''));
  } catch (_) {}
}

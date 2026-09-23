import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Joining and leaving Realtime channels, shared by every repository that
/// uses one. Both halves exist because the wrong version was written twice:
/// a teardown awaited on a failure path hangs the path meant to stop the
/// screen hanging.

/// Subscribes [channel] and completes once the server confirms the join.
///
/// Fails on `channelError`, `timedOut`, any reported error, or after
/// [timeout] -- a refused private channel and an unreachable server both end
/// here instead of hanging.
Future<void> joinChannel(
  RealtimeChannel channel, {
  Duration timeout = const Duration(seconds: 15),
}) {
  final joined = Completer<void>();
  channel.subscribe((status, error) {
    if (joined.isCompleted) return;
    if (status == RealtimeSubscribeStatus.subscribed) {
      joined.complete();
    } else if (status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.timedOut ||
        error != null) {
      joined.completeError(error ?? status);
    }
  });
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

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One queue for everything that opens locked data with the Olm engine: locked texts and locked reactions share the same ratchets, and a peer's chain keeps only its last 40 skipped keys, so openings must run one after another in the order they were asked (messages of a chat before its reactions).
class OpenQueue {
  Future<void> _tail = Future<void>.value();

  /// Runs [job] after every job queued before it; a failed job does not stop the queue.
  Future<T> run<T>(Future<T> Function() job) {
    final r = _tail.then((_) => job());
    _tail = r.then<void>((_) {}, onError: (_) {});
    return r;
  }
}

/// The queue shared by the message opener and the reaction opener.
final openQueueProvider = Provider<OpenQueue>((_) => OpenQueue());

import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One queue for everything that opens locked data with the Olm engine: locked texts and locked reactions share the same ratchets, and a peer's chain keeps only its last 40 skipped keys, so openings run strictly one at a time. Jobs run in the order asked, except that a [low] job (a reaction) waits for every normal job (a text) already waiting; the job running is never interrupted.
class OpenQueue {
  final _high = ListQueue<_Entry>();
  final _low = ListQueue<_Entry>();
  bool _running = false;

  /// Runs [job] when its turn comes; a failed job does not stop the queue.
  Future<T> run<T>(Future<T> Function() job, {bool low = false}) {
    final c = Completer<T>();
    (low ? _low : _high).add(
      _Entry(() async {
        try {
          c.complete(await job());
        } catch (e, s) {
          c.completeError(e, s);
        }
      }),
    );
    if (!_running) unawaited(_pump());
    return c.future;
  }

  Future<void> _pump() async {
    _running = true;
    while (_high.isNotEmpty || _low.isNotEmpty) {
      final e = _high.isNotEmpty ? _high.removeFirst() : _low.removeFirst();
      await e.start();
    }
    _running = false;
  }
}

class _Entry {
  _Entry(this.start);
  final Future<void> Function() start;
}

/// The queue shared by the message opener and the reaction opener.
final openQueueProvider = Provider<OpenQueue>((_) => OpenQueue());

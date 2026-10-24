import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tells whether the message catch-up (the store sync's change feed) has run completely AFTER a given moment. A locked reaction may only be opened once every older message of its sender was opened (they share one Olm chain that keeps only its last 40 skipped keys), so a reaction read at stamp s waits for a feed pass that BEGAN after s and was read to its end.
class CatchUpMark {
  int _ticks = 0;
  int _doneStart = -1;
  bool _holding = false;
  final _passes = StreamController<void>.broadcast();

  /// A new stamp: later than every earlier one.
  int stamp() => ++_ticks;

  /// True when a complete feed pass began after [stamp].
  bool covers(int stamp) => _doneStart > stamp;

  /// A feed pass that began at [start] (from [stamp]) was read to its end.
  void passDone(int start) {
    if (start > _doneStart) _doneStart = start;
    _passes.add(null);
  }

  /// Fires after each complete pass.
  Stream<void> get passes => _passes.stream;

  /// Set by the reaction opener when it kept locked reactions hidden.
  void hold() => _holding = true;

  /// True once (and clears) if reactions were kept hidden since the last call.
  bool takeHolding() {
    final h = _holding;
    _holding = false;
    return h;
  }
}

/// One mark for the app.
final catchUpMarkProvider = Provider<CatchUpMark>((_) => CatchUpMark());

import 'package:flutter/foundation.dart';

/// Timing marks for cold start, label and milliseconds only, never any data.
/// Enable in profile builds with --dart-define=SIS_STARTUP_MARKS=true.
abstract final class StartupMarks {
  static final Stopwatch _clock = Stopwatch()..start();
  static final Set<String> _seen = {};
  static const bool _enabled = bool.fromEnvironment('SIS_STARTUP_MARKS');

  static void mark(String label) {
    if ((kDebugMode || _enabled) && _seen.add(label)) {
      debugPrint('sis.startup $label +${_clock.elapsedMilliseconds}ms');
    }
  }
}

import 'package:flutter/foundation.dart';

/// Timing marks for cold start, label and milliseconds only, never any data.
/// Logged in every build; read on a phone with `adb logcat -s flutter | grep sis.startup`.
abstract final class StartupMarks {
  static final Stopwatch _clock = Stopwatch()..start();
  static final Set<String> _seen = {};

  static void mark(String label) {
    if (_seen.add(label)) {
      debugPrint('sis.startup $label +${_clock.elapsedMilliseconds}ms');
    }
  }
}

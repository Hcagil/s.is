import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How a hold ended; the capture layer and the record bar animate it.
enum VoiceExit { none, sent, cancelled }

/// Pixels of upward travel that lock a recording.
const double voiceLockDistance = 57;

/// Pixels of leftward travel to cancel, on a screen [screenWidth] wide: the
/// smaller of 35% of the width and 140.
double voiceCancelDistance(double screenWidth) =>
    math.min(screenWidth * 0.35, 140);

/// What the finger is doing now, shared by the voice button, the record bar and
/// the capture layer. [slide] is 1 at rest and 0 at the cancel distance; [lift]
/// is the upward travel in pixels, 0..voiceLockDistance.
class VoiceGesture extends ChangeNotifier {
  double _slide = 1;
  double _lift = 0;
  VoiceExit _exit = VoiceExit.none;

  /// 1 at rest, 0 at the cancel distance.
  double get slide => _slide;

  /// Upward travel in pixels.
  double get lift => _lift;

  /// How the hold ended, or none while it goes on.
  VoiceExit get exit => _exit;

  /// Sets any of the fields; notifies once, only when something changed.
  void update({double? slide, double? lift, VoiceExit? exit}) {
    var changed = false;
    if (slide != null) {
      final v = slide.clamp(0.0, 1.0);
      if (v != _slide) {
        _slide = v;
        changed = true;
      }
    }
    if (lift != null) {
      final v = lift.clamp(0.0, voiceLockDistance);
      if (v != _lift) {
        _lift = v;
        changed = true;
      }
    }
    if (exit != null && exit != _exit) {
      _exit = exit;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Back to rest (slide 1, lift 0, exit none); notifies when it changed.
  void reset() {
    final changed = _slide != 1 || _lift != 0 || _exit != VoiceExit.none;
    _slide = 1;
    _lift = 0;
    _exit = VoiceExit.none;
    if (changed) notifyListeners();
  }
}

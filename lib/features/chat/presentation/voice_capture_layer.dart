import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import 'voice_capture_views.dart';
import 'voice_gesture.dart';

/// The floating part of the voice / dictation button while it is held: the
/// circle with its halos, the lock pill and the dictation card. It lives in an
/// OverlayEntry and is placed around [centre], the mic button's centre in
/// global coordinates. Every number is copied from the approved mock.
class VoiceCaptureLayer extends ConsumerStatefulWidget {
  /// Creates the layer.
  const VoiceCaptureLayer({
    super.key,
    required this.centre,
    required this.gesture,
    required this.conversationId,
    required this.onDone,
  });

  /// Global position of the mic button centre.
  final Offset centre;

  /// What the finger is doing, shared with the button and the record bar.
  final VoiceGesture gesture;

  /// The conversation whose message box shows the dictated text.
  final String conversationId;

  /// Called once when the layer has finished; the owner removes the entry.
  final VoidCallback onDone;

  @override
  ConsumerState<VoiceCaptureLayer> createState() => _VoiceCaptureLayerState();
}

class _VoiceCaptureLayerState extends ConsumerState<VoiceCaptureLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  StreamSubscription<double>? _levelsSub;
  bool _done = false;
  Duration? _last;
  Duration? _exitAt;
  VoiceExit _exitKind = VoiceExit.none;

  double _sc0 = 0;
  double _lockV = 1;
  double _amp = 0;
  double _ampTarget = 0;
  double _lc = 8;
  double _closedV = 0;
  double _escShown = 0;
  double _dxShown = 0;
  double _pillTop = -110;

  double _circleScale = 0;
  double _circleDx = 0;
  double _circleOpacity = 1;
  double _pillScale = 0;
  double _pillRotDeg = 0;
  double _pillHeight = 36;
  bool _isLocked = false;

  double _exitEsc = 0;
  double _exitDx = 0;
  double _exitPillScale = 0;

  @override
  void initState() {
    super.initState();
    if (ref.read(voiceCaptureProvider).mode == VoiceMode.voice) {
      _levelsSub = ref.read(voiceRecorderProvider).levels.listen((v) {
        _ampTarget = v.clamp(0.0, 1.0);
      });
    }
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    unawaited(_levelsSub?.cancel());
    super.dispose();
  }

  double get _dist => voiceCancelDistance(MediaQuery.sizeOf(context).width);

  static double _scaleCurve(double s) => s <= .5
      ? s / .5
      : s <= .75
      ? 1 - (s - .5) / .25 * .1
      : .9 + (s - .75) / .25 * .1;

  void _onTick(Duration elapsed) {
    final dt = _last == null
        ? 16.0
        : math.max(1, math.min(50, (elapsed - _last!).inMilliseconds)) + 0.0;
    _last = elapsed;
    final cap = ref.read(voiceCaptureProvider);
    final g = widget.gesture;

    if (_exitAt == null) {
      if (g.exit != VoiceExit.none) {
        _startExit(g.exit, elapsed);
      } else if (cap.phase == VoicePhase.idle) {
        if (cap.notice == VoiceNotice.micDenied ||
            cap.notice == VoiceNotice.micFailed ||
            cap.notice == VoiceNotice.dictationUnavailable) {
          _finish();
          return;
        }
        g.update(exit: VoiceExit.sent);
        _startExit(VoiceExit.sent, elapsed);
      }
    }

    final exitAt = _exitAt;
    if (exitAt != null) {
      final t = (elapsed - exitAt).inMilliseconds.toDouble();
      if (_exitKind == VoiceExit.sent) {
        final u = Curves.easeIn.transform((t / 360).clamp(0.0, 1.0));
        _circleScale = _exitEsc * (1 - u);
        _circleDx = _exitDx * (1 - u);
        _pillScale = _exitPillScale * (1 - (t / 250).clamp(0.0, 1.0));
        if (t >= 360) _finish();
      } else {
        final u = Curves.easeOut.transform((t / 200).clamp(0.0, 1.0));
        _circleScale = _exitEsc * (1 - u);
        _circleDx = _exitDx * (1 - u);
        _circleOpacity = 1 - u;
        _pillScale = _exitPillScale * (1 - u);
        if (t >= 900) _finish();
      }
      if (mounted) setState(() {});
      return;
    }

    final locked = cap.phase == VoicePhase.locked;
    final p = g.slide;
    final yAdd = locked ? 0.0 : g.lift;
    final mv = 1 - yAdd / voiceLockDistance;
    final idle = (math.sin(elapsed.inMilliseconds / 500) + 1) / 2;

    if (!locked) _sc0 = math.min(1.0, _sc0 + dt / 260);
    final sc = _scaleCurve(_sc0 * .999);
    final esc = locked ? 1.0 : sc * (.7 + p * .3);
    if (locked) {
      final k = 1 - math.exp(-dt / 70);
      _escShown += (1.0 - _escShown) * k;
      _dxShown += (0.0 - _dxShown) * k;
    } else {
      _escShown = esc;
      _dxShown = -_dist * (1 - p);
    }

    _lockV = p < .7 ? math.max(0.0, _lockV - .12) : math.min(1.0, _lockV + .12);

    final target =
        -110 - yAdd + (1 - sc) * 30 + (locked ? 14 : 0) - mv * idle * 8;
    if (locked) {
      _pillTop += (target - _pillTop) * (1 - math.exp(-dt / 80));
    } else {
      _pillTop = target;
    }
    _lc += ((locked ? 12.0 : 8 + 2 * idle * mv) - _lc) * (locked ? .25 : 1.0);
    _closedV += ((locked ? 1.0 : 0.0) - _closedV) * .25;

    if (cap.mode == VoiceMode.dictation) {
      _ampTarget = .35 + .25 * math.sin(elapsed.inMilliseconds / 1000 * 6.0);
    }
    _amp += (_ampTarget - _amp) * .4;

    _circleScale = _escShown;
    _circleDx = _dxShown;
    _circleOpacity = 1;
    _pillScale = math.min(sc, _lockV);
    _pillRotDeg = locked ? 0 : 9 * mv;
    _pillHeight = locked ? 36 : 36 + 14 * mv;
    _isLocked = locked;
    if (mounted) setState(() {});
  }

  void _startExit(VoiceExit kind, Duration at) {
    _exitAt = at;
    _exitKind = kind;
    _exitEsc = _circleScale;
    _exitDx = _circleDx;
    _exitPillScale = _pillScale;
  }

  void _send() {
    unawaited(ref.read(voiceCaptureProvider.notifier).finish());
    widget.gesture.update(exit: VoiceExit.sent);
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _ticker.stop();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final cap = ref.watch(voiceCaptureProvider);
    final c = widget.centre;
    final showCard =
        cap.phase == VoicePhase.held && widget.gesture.exit == VoiceExit.none;
    final amplitude = _amp * (_isLocked ? .5 : 1);
    final circle = VoiceCircleView(
      scale: _circleScale,
      amplitude: amplitude,
      opacity: _circleOpacity,
      locked: _isLocked,
    );
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (cap.mode == VoiceMode.dictation)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.sizeOf(context).height - (c.dy - 38),
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: showCard ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: VoiceDictationCard(
                    text: ref.watch(
                      draftsProvider.select(
                        (m) => m[widget.conversationId]?.text ?? '',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: c.dx - 18,
            top: c.dy + _pillTop,
            child: IgnorePointer(
              child: Transform.scale(
                scale: _pillScale,
                child: Transform.rotate(
                  angle: _pillRotDeg * math.pi / 180,
                  child: VoicePillView(
                    height: _pillHeight,
                    closed: _closedV,
                    legEnd: _lc,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: c.dx + _circleDx - 41,
            top: c.dy - 41,
            child: _isLocked && widget.gesture.exit == VoiceExit.none
                ? GestureDetector(
                    key: const ValueKey('voice-circle-send'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _send,
                    child: circle,
                  )
                : IgnorePointer(child: circle),
          ),
        ],
      ),
    );
  }
}

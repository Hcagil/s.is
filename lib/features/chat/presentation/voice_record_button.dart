import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import 'voice_capture_layer.dart';
import 'voice_gesture.dart';
import 'voice_icons.dart';

/// The voice / dictation button in the composer.
class VoiceRecordButton extends ConsumerStatefulWidget {
  /// Creates a button.
  const VoiceRecordButton({
    super.key,
    required this.conversationId,
    required this.gesture,
  });

  /// The conversation whose message box shows the dictated text.
  final String conversationId;

  /// What the finger is doing, shared with the capture layer.
  final VoiceGesture gesture;

  @override
  ConsumerState<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

class _VoiceRecordButtonState extends ConsumerState<VoiceRecordButton> {
  Timer? _pending;
  bool _down = false;
  bool _started = false;
  Offset? _downAt;
  Offset? _origin;
  OverlayEntry? _entry;
  late final VoiceCapture _capture;

  @override
  void initState() {
    super.initState();
    _capture = ref.read(voiceCaptureProvider.notifier);
  }

  @override
  void dispose() {
    _pending?.cancel();
    _entry?.remove();
    _entry?.dispose();
    if (_started) {
      unawaited(_capture.cancel());
    }
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    if (_down) return;
    final cap = ref.read(voiceCaptureProvider);
    if (cap.phase != VoicePhase.idle || widget.gesture.exit != VoiceExit.none) {
      return;
    }
    _down = true;
    _started = false;
    _downAt = e.position;
    _origin = null;
    _pending = Timer(const Duration(milliseconds: 150), _start);
  }

  void _start() {
    _pending = null;
    if (!_down || !mounted) return;
    _started = true;
    widget.gesture.reset();
    HapticFeedback.mediumImpact();
    final box = context.findRenderObject()! as RenderBox;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    _entry = OverlayEntry(
      builder: (_) => VoiceCaptureLayer(
        centre: centre,
        gesture: widget.gesture,
        conversationId: widget.conversationId,
        onDone: _layerDone,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    final tag = Localizations.localeOf(context).languageCode == 'tr'
        ? 'tr_TR'
        : 'en_US';
    unawaited(_capture.begin(widget.conversationId, tag));
  }

  void _onMove(PointerMoveEvent e) {
    if (!_down) return;
    if (!_started) {
      if ((e.position - _downAt!).distance > 24) {
        _pending?.cancel();
        _pending = null;
        _down = false;
      }
      return;
    }
    if (ref.read(voiceCaptureProvider).phase != VoicePhase.held ||
        widget.gesture.exit != VoiceExit.none) {
      return;
    }
    final o = _origin ??= e.position;
    final cancelDist = voiceCancelDistance(MediaQuery.sizeOf(context).width);
    final al = (1 + (e.position.dx - o.dx) / cancelDist).clamp(0.0, 1.0);
    final lift = (o.dy - e.position.dy).clamp(0.0, voiceLockDistance);
    widget.gesture.update(slide: al, lift: lift);
    if (o.dy - e.position.dy >= voiceLockDistance && al >= .7) {
      _capture.lock();
      widget.gesture.update(slide: 1, lift: 0);
      HapticFeedback.selectionClick();
      return;
    }
    if (al == 0) _cancelRec();
  }

  void _onUp(PointerUpEvent e) {
    final wasStarted = _started;
    _pending?.cancel();
    _pending = null;
    if (!_down) return;
    _down = false;
    if (!wasStarted) {
      _capture.toggleMode();
      HapticFeedback.selectionClick();
      return;
    }
    final cap = ref.read(voiceCaptureProvider);
    if (cap.phase == VoicePhase.held && widget.gesture.exit == VoiceExit.none) {
      if (widget.gesture.slide < .45) {
        _cancelRec();
      } else {
        _release();
      }
    }
  }

  void _onCancel(PointerCancelEvent e) {
    _pending?.cancel();
    _pending = null;
    final wasStarted = _started;
    if (!_down) return;
    _down = false;
    if (wasStarted &&
        ref.read(voiceCaptureProvider).phase == VoicePhase.held &&
        widget.gesture.exit == VoiceExit.none) {
      _cancelRec();
    }
  }

  void _cancelRec() {
    widget.gesture.update(exit: VoiceExit.cancelled);
    unawaited(_capture.cancel());
  }

  void _release() {
    widget.gesture.update(exit: VoiceExit.sent);
    unawaited(_capture.finish());
  }

  void _layerDone() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _started = false;
    _down = false;
    widget.gesture.reset();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    ref.listen(voiceCaptureProvider.select((s) => s.notice), (_, notice) {
      if (notice == null) return;
      final text = switch (notice) {
        VoiceNotice.micDenied => l.voiceMicDenied,
        VoiceNotice.micFailed => l.voiceMicFailed,
        VoiceNotice.dictationUnavailable => l.voiceDictationUnavailable,
        VoiceNotice.tooShort => l.voiceHoldHint,
      };
      showSisNotice(context, text, isError: notice != VoiceNotice.tooShort);
      _capture.consumeNotice();
    });
    final mode = ref.watch(voiceCaptureProvider.select((s) => s.mode));
    final recording = ref.watch(
      voiceCaptureProvider.select((s) => s.phase != VoicePhase.idle),
    );
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: Semantics(
        button: true,
        label: mode == VoiceMode.voice
            ? l.voiceButtonVoice
            : l.voiceButtonDictation,
        child: ListenableBuilder(
          listenable: widget.gesture,
          builder: (_, _) {
            final hidden = recording || widget.gesture.exit != VoiceExit.none;
            return Opacity(
              opacity: hidden ? 0 : 1,
              child: SizedBox(
                key: const ValueKey('composer-voice'),
                width: 48,
                height: 48,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: VoiceGlyph(
                      key: ValueKey(
                        mode == VoiceMode.voice
                            ? 'voice-mode-voice'
                            : 'voice-mode-dictation',
                      ),
                      kind: mode == VoiceMode.voice
                          ? VoiceGlyphKind.micOutline
                          : VoiceGlyphKind.dictation,
                      color: SisBrand.of(context).muted,
                      size: 26,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

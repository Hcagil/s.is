import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import '../domain/voice.dart';
import 'voice_gesture.dart';
import 'voice_icons.dart';

/// A bar that appears during voice recording, showing the timer and controls.
class VoiceRecordBar extends ConsumerStatefulWidget {
  /// Creates a voice record bar.
  const VoiceRecordBar({
    super.key,
    required this.gesture,
    required this.conversationId,
  });

  /// The gesture state shared with the button and capture layer.
  final VoiceGesture gesture;

  /// The conversation ID for draft text.
  final String conversationId;

  @override
  ConsumerState<VoiceRecordBar> createState() => _VoiceRecordBarState();
}

class _VoiceRecordBarState extends ConsumerState<VoiceRecordBar>
    with TickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  late final AnimationController _bin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 870),
  );

  int _shownMs = 0;

  @override
  void initState() {
    super.initState();
    widget.gesture.addListener(_handleGestureChange);
  }

  @override
  void dispose() {
    widget.gesture.removeListener(_handleGestureChange);
    _blink.dispose();
    _bin.dispose();
    super.dispose();
  }

  void _handleGestureChange() {
    if (widget.gesture.exit == VoiceExit.cancelled && !_bin.isAnimating) {
      _bin.forward(from: 0);
    } else if (widget.gesture.exit == VoiceExit.none) {
      _bin.value = 0;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _blink, builder: (c, _) => _content(c));

  Widget _content(BuildContext context) {
    final state = ref.watch(voiceCaptureProvider);
    final l = AppLocalizations.of(context);
    final theme = SisBrand.of(context);

    if (state.phase != VoicePhase.idle) {
      _shownMs = state.elapsedMs;
    }

    final locked = state.phase == VoicePhase.locked;
    final cancelled = widget.gesture.exit == VoiceExit.cancelled;
    final slide = widget.gesture.slide;

    // Wobble effect when slide > 0.8
    final double wobble = slide > 0.8
        ? 6 * math.sin(_blink.value * 2 * math.pi * 1.2)
        : 0;

    return SizedBox(
      height: 48,
      key: const ValueKey('voice-bar'),
      child: Stack(
        children: [
          // LEFT group
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Row(
              children: [
                // Voice dot or bin
                SizedBox(
                  width: 28,
                  height: 28,
                  key: const ValueKey('voice-dot-or-bin'),
                  child: Stack(
                    children: [
                      // Red dot
                      Positioned(
                        left: 9,
                        top: 9,
                        child: Opacity(
                          opacity: cancelled ? 0 : 1,
                          child: AnimatedBuilder(
                            animation: _blink,
                            builder: (context, child) {
                              final v = _blink.value;
                              final opacity = v < 0.5 ? 1 - 2 * v : 2 * v - 1;
                              return Opacity(
                                opacity: opacity,
                                child: Container(
                                  key: const ValueKey('voice-dot'),
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: theme.danger,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      // Bin
                      if (cancelled)
                        Opacity(
                          opacity: _bin.value < 0.22
                              ? _bin.value / 0.22
                              : _bin.value > 0.85
                              ? 1 - (_bin.value - 0.85) / 0.15
                              : 1,
                          child: Transform.scale(
                            scale: _bin.value < 0.22
                                ? 0.4 + 0.6 * (_bin.value / 0.22)
                                : _bin.value > 0.85
                                ? 1 - 0.8 * ((_bin.value - 0.85) / 0.15)
                                : 1,
                            child: VoiceBinIcon(
                              lid: _bin.value < 0.22
                                  ? 0
                                  : _bin.value < 0.38
                                  ? (_bin.value - 0.22) / 0.16
                                  : _bin.value <= 0.62
                                  ? 1
                                  : _bin.value < 0.78
                                  ? 1 - (_bin.value - 0.62) / 0.16
                                  : 0,
                              color: theme.danger,
                              barColor: theme.surface,
                              size: 28,
                              key: const ValueKey('voice-bin'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                // Timer
                AnimatedOpacity(
                  opacity: cancelled ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: AnimatedSlide(
                    offset: cancelled ? const Offset(-20 / 60, 0) : Offset.zero,
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      voiceTimer(_shownMs),
                      key: const ValueKey('voice-timer'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: theme.text,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // SLIDE HINT
          Positioned(
            left: 92,
            right: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              key: const ValueKey('voice-slide-hint'),
              ignoring: true,
              child: Center(
                child: Transform.translate(
                  offset: Offset(-90 * (1 - slide) + wobble * slide, 0),
                  child: Opacity(
                    opacity: locked || cancelled ? 0 : slide,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        VoiceGlyph(
                          kind: VoiceGlyphKind.chevron,
                          color: theme.muted,
                          size: 11,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          l.voiceSlideToCancel,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(fontSize: 15, color: theme.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // CANCEL button
          Align(
            alignment: Alignment.center,
            child: AnimatedOpacity(
              opacity: locked ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: AnimatedSlide(
                offset: locked ? Offset.zero : const Offset(0, -0.25),
                duration: const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !locked,
                  child: GestureDetector(
                    key: const ValueKey('voice-cancel'),
                    behavior: HitTestBehavior.opaque,
                    onTap: locked
                        ? () {
                            widget.gesture.update(exit: VoiceExit.cancelled);
                            ref.read(voiceCaptureProvider.notifier).cancel();
                          }
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      child: Text(
                        l.voiceCancel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.56,
                          color: theme.brand,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // DICTATION PREVIEW
          if (state.mode == VoiceMode.dictation && locked)
            Positioned(
              left: 112,
              right: 146,
              top: 0,
              bottom: 0,
              child: Align(
                key: const ValueKey('voice-dictation-preview'),
                alignment: Alignment.centerLeft,
                child: Text(
                  ref.watch(
                    draftsProvider.select(
                      (m) => m[widget.conversationId]?.text ?? '',
                    ),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: theme.text,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

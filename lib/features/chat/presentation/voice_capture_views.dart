import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import 'voice_icons.dart';

/// A circular voice capture indicator with animated halo and icon.
class VoiceCircleView extends StatelessWidget {
  /// Creates a voice circle view.
  const VoiceCircleView({
    super.key,
    required this.scale,
    required this.amplitude,
    required this.opacity,
    required this.locked,
  });

  /// Scale factor for the circle (0..1.2).
  final double scale;

  /// Amplitude of the animation (0..1).
  final double amplitude;

  /// Opacity of the entire view (0..1).
  final double opacity;

  /// Whether the recording is locked.
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return SizedBox(
      key: const ValueKey('voice-circle'),
      width: 82,
      height: 82,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Halo 2
          IgnorePointer(
            ignoring: true,
            child: Opacity(
              opacity: 0.12 * scale * opacity.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: scale * (1.2 + 0.35 * amplitude),
                child: Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: brand.brand,
                  ),
                ),
              ),
            ),
          ),
          // Halo 1
          Opacity(
            opacity: 0.22 * scale * opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale * (1.1 + 0.25 * amplitude),
              child: Container(
                width: 82,
                height: 82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: brand.brand,
                ),
              ),
            ),
          ),
          // Disc
          Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [brand.brandDeep, brand.brand],
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x733D4BE8),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedScale(
                      duration: const Duration(milliseconds: 150),
                      scale: locked ? 0 : 1,
                      child: VoiceGlyph(
                        kind: VoiceGlyphKind.micFilled,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    AnimatedScale(
                      duration: const Duration(milliseconds: 150),
                      scale: locked ? 1 : 0,
                      child: VoiceGlyph(
                        kind: VoiceGlyphKind.send,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A pill-shaped voice capture indicator with a lock icon.
class VoicePillView extends StatelessWidget {
  /// Creates a voice pill view.
  const VoicePillView({
    super.key,
    required this.height,
    required this.closed,
    required this.legEnd,
  });

  /// Height of the pill (36..50).
  final double height;

  /// Closed state of the lock (0..1).
  final double closed;

  /// End position of the right leg (8..12).
  final double legEnd;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return SizedBox(
      key: const ValueKey('voice-pill'),
      width: 36,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: brand.surfaceHigh,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: brand.line),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: OverflowBox(
          alignment: Alignment.center,
          maxWidth: 36,
          maxHeight: 36,
          child: VoiceLockIcon(
            closed: closed,
            legEnd: legEnd,
            color: brand.text,
            size: 36,
          ),
        ),
      ),
    );
  }
}

/// A card showing voice dictation text with a branding indicator.
class VoiceDictationCard extends StatelessWidget {
  /// Creates a voice dictation card.
  const VoiceDictationCard({super.key, required this.text});

  /// The text to display.
  final String text;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return Container(
      key: const ValueKey('voice-dictation-card'),
      decoration: BoxDecoration(
        color: brand.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: brand.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 30,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text.rich(
        TextSpan(
          text: text,
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: SizedBox(
                width: 2,
                height: 15,
                child: ColoredBox(color: brand.brand),
              ),
            ),
          ],
        ),
        style: TextStyle(fontSize: 14, height: 1.45, color: brand.text),
      ),
    );
  }
}

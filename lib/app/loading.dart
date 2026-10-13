import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brand.dart';
import 'theme.dart';

/// The Sync S, gently pulsing: every full-screen and inline wait (replaces
/// CircularProgressIndicator). Static when the platform asks for reduced
/// motion.
class SisLoadingLogo extends StatefulWidget {
  const SisLoadingLogo({super.key, this.size = 72});

  final double size;

  @override
  State<SisLoadingLogo> createState() => _SisLoadingLogoState();
}

class _SisLoadingLogoState extends State<SisLoadingLogo>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = SisLogo(size: widget.size);
    if (MediaQuery.disableAnimationsOf(context)) return logo;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: .55 + .45 * _controller.value,
        child: Transform.scale(
          scale: .92 + .08 * _controller.value,
          child: child,
        ),
      ),
      child: logo,
    );
  }
}

/// A thin ring: the arc of `value` (0..1), or, when null, a quarter arc that
/// turns forever (still when the platform asks for reduced motion). Fills the
/// space it is given.
class SisProgressRing extends StatefulWidget {
  const SisProgressRing({
    super.key,
    this.value,
    required this.color,
    this.strokeWidth = 3,
  });

  final double? value;
  final Color color;
  final double strokeWidth;

  @override
  State<SisProgressRing> createState() => _SisProgressRingState();
}

class _SisProgressRingState extends State<SisProgressRing>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spin =
        widget.value == null && !MediaQuery.disableAnimationsOf(context);
    if (spin && !_c.isAnimating) {
      _c.repeat();
    } else if (!spin && _c.isAnimating) {
      _c.stop();
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(
        painter: _RingPainter(
          value: widget.value,
          turn: _c.value,
          color: widget.color,
          strokeWidth: widget.strokeWidth,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.value,
    required this.turn,
    required this.color,
    required this.strokeWidth,
  });

  final double? value;
  final double turn;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    final sweep = (value ?? 0.25).clamp(0.0, 1.0).toDouble() * 2 * math.pi;
    final start = -math.pi / 2 + (value == null ? turn * 2 * math.pi : 0);
    canvas.drawArc(
      (Offset.zero & size).deflate(strokeWidth / 2),
      start,
      sweep,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.turn != turn ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

/// A full-screen wait: the pulsing logo, centred.
class SisFullScreenLoader extends StatelessWidget {
  const SisFullScreenLoader({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: SisLoadingLogo()));
}

/// A thin brand-gradient line: every small/inline wait (replaces
/// LinearProgressIndicator).
class SisProgressLine extends StatelessWidget {
  const SisProgressLine({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => t.gradient.createShader(bounds),
      child: const LinearProgressIndicator(
        minHeight: 3,
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation(Colors.white),
      ),
    );
  }
}

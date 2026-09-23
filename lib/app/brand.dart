import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Which part of the logo to paint. The launcher icon is built from the three
/// layers Android composes itself (tool/render_icons.dart); the app shows
/// [full].
enum SisLogoLayer { full, background, foreground, monochrome }

/// The Sync S: an S made of two arrows chasing each other, gradient over
/// white, on an ink ground. Drawn on the 108-unit adaptive-icon grid, whose
/// middle 66 units (21..87) survive every launcher mask.
class SisLogoPainter extends CustomPainter {
  const SisLogoPainter([this.layer = SisLogoLayer.full]);

  final SisLogoLayer layer;

  /// The logo keeps its own colours in both themes.
  static const prism = [
    Color(0xFF4450FF),
    Color(0xFF8B5CFF),
    Color(0xFFC45BE6),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 108, size.height / 108);
    if (layer == SisLogoLayer.full || layer == SisLogoLayer.background) {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 108, 108),
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-.4, -.56),
            radius: .8,
            colors: [Color(0xFF2A2466), Color(0xFF0B0920)],
          ).createShader(const Rect.fromLTWH(0, 0, 108, 108)),
      );
    }
    if (layer == SisLogoLayer.background) return;

    final mono = layer == SisLogoLayer.monochrome;
    final gradient = Paint()
      ..shader = const LinearGradient(colors: prism, stops: [0, .55, 1])
          .createShader(
            Rect.fromPoints(const Offset(22, 22), const Offset(86, 86)),
          );
    final top = mono ? (Paint()..color = Colors.white) : gradient;
    final bottom = Paint()..color = Colors.white;
    Paint stroke(Paint p) => Paint()
      ..shader = p.shader
      ..color = p.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.butt;

    canvas
      ..translate(54, 54)
      ..scale(.9)
      ..translate(-54, -54);
    // Upper arrow: from the S's waist round the top bowl, pointing back down.
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(54, 40), radius: 14),
      math.pi / 2,
      3 * math.pi / 2,
      false,
      stroke(top),
    );
    canvas.drawPath(
      Path()
        ..moveTo(60.5, 37.5)
        ..lineTo(75.5, 37.5)
        ..lineTo(68, 48)
        ..close(),
      top,
    );
    // Lower arrow: from the waist round the bottom bowl, pointing back up.
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(54, 68), radius: 14),
      -math.pi / 2,
      3 * math.pi / 2,
      false,
      stroke(bottom),
    );
    canvas.drawPath(
      Path()
        ..moveTo(32.5, 70.5)
        ..lineTo(47.5, 70.5)
        ..lineTo(40, 60)
        ..close(),
      bottom,
    );
  }

  @override
  bool shouldRepaint(SisLogoPainter oldDelegate) => oldDelegate.layer != layer;
}

/// The logo as a rounded tile, as the header and sign-in screen show it.
class SisLogo extends StatelessWidget {
  const SisLogo({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .3),
    child: CustomPaint(
      size: Size.square(size),
      painter: const SisLogoPainter(),
    ),
  );
}

/// "SIS" in Sora, filled with the three-stop gradient.
class SisWordmark extends StatelessWidget {
  const SisWordmark({super.key, this.size = 23});

  final double size;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (bounds) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: SisBrand.of(context).prism.colors,
      stops: SisBrand.of(context).prism.stops,
    ).createShader(bounds),
    child: Text(
      'SIS',
      style: TextStyle(
        fontFamily: 'Sora',
        fontWeight: FontWeight.w800,
        fontSize: size,
        height: 1.1,
        letterSpacing: size * .01,
        color: Colors.white,
      ),
    ),
  );
}

/// Logo and wordmark side by side: the app's header.
class SisBrandRow extends StatelessWidget {
  const SisBrandRow({super.key});

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [SisLogo(), SizedBox(width: 10), SisWordmark()],
  );
}

/// The faint ink-violet light behind a conversation and the sign-in screen.
class SisGlow extends StatelessWidget {
  const SisGlow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    // Fade each glow to its own hue at zero alpha, not to transparent black,
    // so the edge never greys.
    Widget light(Alignment at, Color c, double radius) => Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: at,
              radius: radius,
              colors: [c, c.withAlpha(0)],
            ),
          ),
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        light(Alignment.topRight, t.glow, 1.1),
        light(Alignment.bottomLeft, t.glowDeep, 1.0),
        child,
      ],
    );
  }
}

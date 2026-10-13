import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The glyphs of the voice button and record bar.
enum VoiceGlyphKind { micOutline, micFilled, dictation, send, chevron }

/// A mic, dictation, send or chevron glyph drawn from its vector outline.
class VoiceGlyph extends StatelessWidget {
  /// Creates a glyph of [kind] in [color], [size] tall.
  const VoiceGlyph({
    super.key,
    required this.kind,
    required this.color,
    this.size = 26,
  });

  /// Which glyph.
  final VoiceGlyphKind kind;

  /// Its color.
  final Color color;

  /// Its height (and width, except for the chevron).
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: kind == VoiceGlyphKind.chevron ? size * 6 / 11 : size,
    height: size,
    child: CustomPaint(painter: _GlyphPainter(kind, color)),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.kind, this.color);

  final VoiceGlyphKind kind;
  final Color color;

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.kind != kind || old.color != color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..isAntiAlias = true
      ..color = color;
    switch (kind) {
      case VoiceGlyphKind.micOutline:
        canvas.scale(size.width / 28, size.height / 28);
        _mic(canvas, paint, filled: false);
      case VoiceGlyphKind.micFilled:
        canvas.scale(size.width / 28, size.height / 28);
        _mic(canvas, paint, filled: true);
      case VoiceGlyphKind.dictation:
        canvas.scale(size.width / 28, size.height / 28);
        _dictation(canvas, paint);
      case VoiceGlyphKind.send:
        canvas.scale(size.width / 275, size.height / 275);
        canvas.translate(-595, -190);
        _send(canvas, paint);
      case VoiceGlyphKind.chevron:
        canvas.scale(size.width / 4, size.height / 10);
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawPath(
          Path()
            ..moveTo(4, 0)
            ..lineTo(0, 5)
            ..lineTo(4, 10),
          paint,
        );
    }
  }

  void _mic(Canvas canvas, Paint paint, {required bool filled}) {
    paint
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromLTRBR(10, 2.5, 18, 16.5, const Radius.circular(4)),
      paint,
    );
    paint.style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(5.5, 12.5)
        ..arcToPoint(
          const Offset(22.5, 12.5),
          radius: const Radius.circular(8.5),
          clockwise: false,
        ),
      paint,
    );
    canvas.drawLine(const Offset(14, 21), const Offset(14, 24.5), paint);
  }

  void _dictation(Canvas canvas, Paint paint) {
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const r = Radius.circular(1);
    canvas.drawPath(
      Path()
        ..moveTo(5, 5)
        ..lineTo(23, 5)
        ..arcToPoint(const Offset(24, 6), radius: r)
        ..lineTo(24, 18)
        ..arcToPoint(const Offset(23, 19), radius: r)
        ..lineTo(12, 19)
        ..lineTo(7, 23)
        ..lineTo(7, 19)
        ..lineTo(5, 19)
        ..arcToPoint(const Offset(4, 18), radius: r)
        ..lineTo(4, 6)
        ..arcToPoint(const Offset(5, 5), radius: r)
        ..close(),
      paint,
    );
    canvas.drawLine(const Offset(9, 10), const Offset(19, 10), paint);
    canvas.drawLine(const Offset(9, 14), const Offset(15, 14), paint);
  }

  void _send(Canvas canvas, Paint paint) {
    final path = Path()
      ..moveTo(612, 210)
      ..lineTo(852, 327)
      ..lineTo(612, 445)
      ..lineTo(626, 350)
      ..lineTo(742, 327)
      ..lineTo(626, 303)
      ..close();
    paint.style = PaintingStyle.fill;
    canvas.drawPath(path, paint);
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }
}

/// The bin that replaces the red dot when a recording is cancelled; its lid
/// lifts and drops.
class VoiceBinIcon extends StatelessWidget {
  /// Creates a bin; [lid] is 0 (closed) to 1 (open).
  const VoiceBinIcon({
    super.key,
    required this.lid,
    required this.color,
    required this.barColor,
    this.size = 28,
  });

  /// 0 closed, 1 fully open.
  final double lid;

  /// The bin color.
  final Color color;

  /// The color of the bars cut into the bin.
  final Color barColor;

  /// Width and height.
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _BinPainter(lid, color, barColor)),
  );
}

class _BinPainter extends CustomPainter {
  const _BinPainter(this.lid, this.color, this.barColor);

  final double lid;
  final Color color;
  final Color barColor;

  @override
  bool shouldRepaint(_BinPainter old) =>
      old.lid != lid || old.color != color || old.barColor != barColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 28, size.height / 28);
    final paint = Paint()
      ..isAntiAlias = true
      ..color = color;
    const r = Radius.circular(2.2);
    canvas.drawPath(
      Path()
        ..moveTo(8.2, 10.8)
        ..relativeLineTo(11.6, 0)
        ..relativeLineTo(-0.9, 10.4)
        ..arcToPoint(const Offset(16.7, 23.2), radius: r)
        ..lineTo(11.3, 23.2)
        ..arcToPoint(const Offset(9.1, 21.2), radius: r)
        ..close(),
      paint,
    );
    canvas.save();
    canvas.translate(7, 9 - lid);
    canvas.rotate(-38 * math.pi / 180 * lid);
    canvas.translate(-7, -9);
    canvas.drawRRect(
      RRect.fromLTRBR(7, 7, 21, 9.4, const Radius.circular(1.2)),
      paint,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(11.5, 5, 16.5, 7.6, const Radius.circular(1.2)),
      paint,
    );
    canvas.restore();
    final bars = Paint()
      ..isAntiAlias = true
      ..color = barColor
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    for (final x in const [11.5, 14.0, 16.5]) {
      canvas.drawLine(Offset(x, 13.5), Offset(x, 19.7), bars);
    }
  }
}

/// The padlock of the lock pill: open, then closing into two bars.
class VoiceLockIcon extends StatelessWidget {
  /// Creates a padlock; [closed] is 0 (open) to 1 (locked) and [legEnd] is the
  /// y of the end of the right shackle leg (8..12).
  const VoiceLockIcon({
    super.key,
    required this.closed,
    required this.legEnd,
    required this.color,
    this.size = 36,
  });

  /// 0 open, 1 locked.
  final double closed;

  /// The y of the end of the right shackle leg.
  final double legEnd;

  /// The color.
  final Color color;

  /// Width and height.
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _LockPainter(closed, legEnd, color)),
  );
}

class _LockPainter extends CustomPainter {
  const _LockPainter(this.closed, this.legEnd, this.color);

  final double closed;
  final double legEnd;
  final Color color;

  @override
  bool shouldRepaint(_LockPainter old) =>
      old.closed != closed || old.legEnd != legEnd || old.color != color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 36, size.height / 36);
    final open = 1 - closed;
    if (open > 0) {
      final paint = Paint()
        ..isAntiAlias = true
        ..color = color.withValues(alpha: color.a * open)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round;
      canvas.save();
      canvas.translate(0, 10 * closed);
      canvas.drawPath(
        Path()
          ..moveTo(14, 8)
          ..arcToPoint(const Offset(22, 8), radius: const Radius.circular(4)),
        paint,
      );
      canvas.drawLine(const Offset(22, 8), Offset(22, legEnd), paint);
      canvas.drawLine(const Offset(14, 8), const Offset(14, 9.5), paint);
      canvas.restore();
      paint
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: color.a * open);
      canvas.drawRRect(
        RRect.fromLTRBR(10, 12, 26, 28, const Radius.circular(3)),
        paint,
      );
    }
    if (closed > 0) {
      final paint = Paint()
        ..isAntiAlias = true
        ..color = color.withValues(alpha: color.a * closed);
      canvas.drawRRect(
        RRect.fromLTRBR(12, 12, 16.3, 28, const Radius.circular(1.5)),
        paint,
      );
      canvas.drawRRect(
        RRect.fromLTRBR(19.7, 12, 24, 28, const Radius.circular(1.5)),
        paint,
      );
    }
  }
}

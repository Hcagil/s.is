import 'package:flutter/material.dart';

/// A padlock outline drawn from its vector path.
class LockGlyph extends StatelessWidget {
  /// Creates a lock glyph in [color], [size] tall.
  const LockGlyph({super.key, required this.color, this.size = 14});

  /// Its color.
  final Color color;

  /// Its height (and width).
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _LockPainter(color)),
  );
}

class _LockPainter extends CustomPainter {
  const _LockPainter(this.color);

  final Color color;

  @override
  bool shouldRepaint(_LockPainter old) => old.color != color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..isAntiAlias = true
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(5, 11, 14, 10),
        const Radius.circular(2.5),
      ),
      paint,
    );
    final shackle = Path()
      ..moveTo(8, 11)
      ..lineTo(8, 7.5)
      ..arcToPoint(const Offset(16, 7.5), radius: const Radius.circular(4))
      ..lineTo(16, 11);
    canvas.drawPath(shackle, paint);
  }
}

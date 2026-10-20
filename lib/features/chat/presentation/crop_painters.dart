import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Painter for displaying a cropped photo with rotation.
class CropPhotoPainter extends CustomPainter {
  /// Creates a [CropPhotoPainter] with the given image and turn count.
  const CropPhotoPainter({
    required this.image,
    required this.turns,
    this.spin = 1,
    this.fromScale = 1,
  });

  /// The image to display.
  final ui.Image image;

  /// Number of quarter turns anticlockwise (0..3).
  final int turns;

  /// Progress (0..1) of the last 90 degree anticlockwise turn; 1 = finished.
  final double spin;

  /// Size of the previous orientation relative to the new one.
  final double fromScale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final q = spin >= 1
        ? turns.toDouble()
        : (turns == 0 ? 4 : turns) - 1 + spin;
    canvas.rotate(-q * math.pi / 2);
    final s = fromScale + (1 - fromScale) * spin;
    final odd = turns.isOdd;
    final w = odd ? size.height : size.width;
    final h = odd ? size.width : size.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: w * s, height: h * s),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(CropPhotoPainter old) {
    return old.image != image ||
        old.turns != turns ||
        old.spin != spin ||
        old.fromScale != fromScale;
  }
}

/// Painter for displaying a crop frame over a photo.
class CropFramePainter extends CustomPainter {
  /// Creates a [CropFramePainter] with the given frame rectangle.
  const CropFramePainter({
    required this.frame,
    required this.veil,
    this.gridOpacity = 0,
  });

  /// The frame rectangle in painter space (the whole area).
  final Rect frame;

  /// Colour of the dim outside the frame.
  final Color veil;

  /// 0..1 visibility of the grid lines.
  final double gridOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    // Dimming overlay
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(path, Paint()..color = veil);

    // Grid lines
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6 * gridOpacity)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final w = frame.width;
    final h = frame.height;
    final left = frame.left;
    final top = frame.top;

    if (gridOpacity > 0) {
      // Vertical lines
      canvas.drawLine(
        Offset(left + w / 3, top),
        Offset(left + w / 3, top + h),
        gridPaint,
      );
      canvas.drawLine(
        Offset(left + 2 * w / 3, top),
        Offset(left + 2 * w / 3, top + h),
        gridPaint,
      );

      // Horizontal lines
      canvas.drawLine(
        Offset(left, top + h / 3),
        Offset(left + w, top + h / 3),
        gridPaint,
      );
      canvas.drawLine(
        Offset(left, top + 2 * h / 3),
        Offset(left + w, top + 2 * h / 3),
        gridPaint,
      );
    }

    // Edge outline
    canvas.drawRect(
      frame.shift(const Offset(0, 1)),
      Paint()
        ..color = const Color(0x59000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Corner handles
    final l = frame.left;
    final t = frame.top;
    final r = frame.right;
    final b = frame.bottom;

    final handlePaint = Paint()..color = Colors.white;

    final arms = <Rect>[
      Rect.fromLTWH(l - 1, t - 1, 16, 3),
      Rect.fromLTWH(l - 1, t - 1, 3, 16),
      Rect.fromLTWH(r + 1 - 16, t - 1, 16, 3),
      Rect.fromLTWH(r + 1 - 3, t - 1, 3, 16),
      Rect.fromLTWH(l - 1, b + 1 - 3, 16, 3),
      Rect.fromLTWH(l - 1, b + 1 - 16, 3, 16),
      Rect.fromLTWH(r + 1 - 16, b + 1 - 3, 16, 3),
      Rect.fromLTWH(r + 1 - 3, b + 1 - 16, 3, 16),
    ];

    final shadow = Paint()
      ..color = const Color(0x59000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    for (final a in arms) {
      canvas.drawRect(a.shift(const Offset(0, 1)), shadow);
    }

    for (final a in arms) {
      canvas.drawRect(a, handlePaint);
    }
  }

  @override
  bool shouldRepaint(CropFramePainter old) {
    return old.frame != frame ||
        old.veil != veil ||
        old.gridOpacity != gridOpacity;
  }
}

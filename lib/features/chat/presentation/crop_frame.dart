import 'dart:math' as math;
import 'dart:ui';

/// The whole photo.
const Rect fullFrame = Rect.fromLTRB(0, 0, 1, 1);

/// [f] after the photo is turned 90 degrees anticlockwise: (x, y) -> (y, 1-x).
Rect rotateFrameCcw(Rect f) =>
    Rect.fromLTRB(f.top, 1 - f.right, f.bottom, 1 - f.left);

/// The largest centred frame (fractions) whose pixel width / height is [ratio].
Rect fitRatio({
  required double ratio,
  required double photoW,
  required double photoH,
}) {
  final wf = photoW / photoH > ratio ? ratio * photoH / photoW : 1.0;
  final hf = photoW / photoH > ratio ? 1.0 : photoW / ratio / photoH;
  final left = (1 - wf) / 2;
  final top = (1 - hf) / 2;
  return Rect.fromLTWH(left, top, wf, hf);
}

/// Which part of the frame a finger is on.
enum FrameGrab {
  none,
  move,
  left,
  top,
  right,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// The part of [frame] under [p] (same pixel space), within [slop].
FrameGrab grabAt(Offset p, Rect frame, {double slop = 24}) {
  final corners = [
    Offset(frame.left, frame.top),
    Offset(frame.right, frame.top),
    Offset(frame.left, frame.bottom),
    Offset(frame.right, frame.bottom),
  ];
  const cornerGrabs = [
    FrameGrab.topLeft,
    FrameGrab.topRight,
    FrameGrab.bottomLeft,
    FrameGrab.bottomRight,
  ];
  for (var i = 0; i < 4; i++) {
    if ((p.dx - corners[i].dx).abs() <= slop &&
        (p.dy - corners[i].dy).abs() <= slop) {
      return cornerGrabs[i];
    }
  }
  final inY = p.dy >= frame.top - slop && p.dy <= frame.bottom + slop;
  final inX = p.dx >= frame.left - slop && p.dx <= frame.right + slop;
  if (inY && (p.dx - frame.left).abs() <= slop) return FrameGrab.left;
  if (inY && (p.dx - frame.right).abs() <= slop) return FrameGrab.right;
  if (inX && (p.dy - frame.top).abs() <= slop) return FrameGrab.top;
  if (inX && (p.dy - frame.bottom).abs() <= slop) return FrameGrab.bottom;
  if (frame.contains(p)) return FrameGrab.move;
  return FrameGrab.none;
}

/// [frame] (fractions) after dragging [grab] by [delta] pixels on a photo
/// shown [photo] pixels big. [minSide] is the smallest side in pixels; with a
/// [ratio] (width / height) only corners resize and the ratio is kept.
Rect dragFrame({
  required Rect frame,
  required FrameGrab grab,
  required Offset delta,
  required Size photo,
  required double minSide,
  double? ratio,
}) {
  final dx = delta.dx / photo.width;
  final dy = delta.dy / photo.height;
  final minW = minSide / photo.width;
  final minH = minSide / photo.height;
  double l() => (frame.left + dx).clamp(0.0, frame.right - minW).toDouble();
  double t() => (frame.top + dy).clamp(0.0, frame.bottom - minH).toDouble();
  double r() => (frame.right + dx).clamp(frame.left + minW, 1.0).toDouble();
  double b() => (frame.bottom + dy).clamp(frame.top + minH, 1.0).toDouble();

  switch (grab) {
    case FrameGrab.none:
      return frame;
    case FrameGrab.move:
      final w = frame.width;
      final h = frame.height;
      return Rect.fromLTWH(
        (frame.left + dx).clamp(0.0, 1.0 - w).toDouble(),
        (frame.top + dy).clamp(0.0, 1.0 - h).toDouble(),
        w,
        h,
      );
    case FrameGrab.left:
      if (ratio != null) return frame;
      return Rect.fromLTRB(l(), frame.top, frame.right, frame.bottom);
    case FrameGrab.top:
      if (ratio != null) return frame;
      return Rect.fromLTRB(frame.left, t(), frame.right, frame.bottom);
    case FrameGrab.right:
      if (ratio != null) return frame;
      return Rect.fromLTRB(frame.left, frame.top, r(), frame.bottom);
    case FrameGrab.bottom:
      if (ratio != null) return frame;
      return Rect.fromLTRB(frame.left, frame.top, frame.right, b());
    case FrameGrab.topLeft:
    case FrameGrab.topRight:
    case FrameGrab.bottomLeft:
    case FrameGrab.bottomRight:
      if (ratio != null) {
        return _dragCornerLocked(
          frame: frame,
          grab: grab,
          dx: dx,
          dy: dy,
          photo: photo,
          minSide: minSide,
          ratio: ratio,
        );
      }
      final left = grab == FrameGrab.topLeft || grab == FrameGrab.bottomLeft;
      final top = grab == FrameGrab.topLeft || grab == FrameGrab.topRight;
      return Rect.fromLTRB(
        left ? l() : frame.left,
        top ? t() : frame.top,
        left ? frame.right : r(),
        top ? frame.bottom : b(),
      );
  }
}

/// A corner drag that keeps the opposite corner fixed and the pixel ratio.
Rect _dragCornerLocked({
  required Rect frame,
  required FrameGrab grab,
  required double dx,
  required double dy,
  required Size photo,
  required double minSide,
  required double ratio,
}) {
  final dragRight = grab == FrameGrab.topRight || grab == FrameGrab.bottomRight;
  final dragBottom =
      grab == FrameGrab.bottomLeft || grab == FrameGrab.bottomRight;
  final ax = dragRight ? frame.left : frame.right;
  final ay = dragBottom ? frame.top : frame.bottom;
  final sx = dragRight ? 1.0 : -1.0;
  final sy = dragBottom ? 1.0 : -1.0;
  final x = dragRight ? frame.right : frame.left;
  final wPx = sx * (x + dx - ax) * photo.width;
  final maxWx = (dragRight ? 1.0 - ax : ax) * photo.width;
  final maxWy = (dragBottom ? 1.0 - ay : ay) * photo.height * ratio;
  final hi = math.min(maxWx, maxWy);
  final lo = math.max(minSide, minSide * ratio);
  final w = hi < lo ? hi : wPx.clamp(lo, hi).toDouble();
  final x2 = ax + sx * w / photo.width;
  final y2 = ay + sy * (w / ratio) / photo.height;
  return Rect.fromLTRB(
    math.min(ax, x2),
    math.min(ay, y2),
    math.max(ax, x2),
    math.max(ay, y2),
  );
}

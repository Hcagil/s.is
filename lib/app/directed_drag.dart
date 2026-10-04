import 'package:flutter/gestures.dart';

/// A horizontal drag that wins the gesture arena only when the finger moves
/// toward [direction] (+1 = right, -1 = left) AND the move so far is mostly
/// horizontal (|dx| > 2*|dy|). Swipe-left-to-reply on a message and
/// drag-right-to-leave on a page therefore never fight each other, or a
/// vertical scroll. Starts with [DragStartBehavior.down], so the first update
/// already carries the distance travelled before the drag was recognised:
/// the bubble or page is under the finger at once.
class DirectedDragRecognizer extends HorizontalDragGestureRecognizer {
  DirectedDragRecognizer({required this.direction, super.debugOwner}) {
    dragStartBehavior = DragStartBehavior.down;
  }

  final double direction;

  double _dy = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _dy = 0;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _dy += event.delta.dy;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved * direction >
          computeHitSlop(pointerDeviceKind, gestureSettings) &&
      globalDistanceMoved.abs() > 2 * _dy.abs();
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One row of a [showMenuCard] card. [value] is what the card returns when
/// the row is tapped; [keyId] names the row's test key (`menu-<keyId>`).
class MenuCardAction<T> {
  const MenuCardAction({
    required this.value,
    required this.keyId,
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final T value;
  final String keyId;
  final IconData icon;
  final String label;
  final bool destructive;
}

/// Opens a floating card of [actions] next to [anchor] (global coordinates)
/// and returns the tapped row's value, or null when it was closed without
/// choosing (tap outside, Back).
///
/// The card sits above [anchor], or below it when there is no room above, and
/// is always fully on screen. The rest of the screen is dimmed; with
/// [highlightAnchor] the anchor itself stays bright and lifted, so the card
/// never hides it. [alignEnd] lines the card's right edge up with the
/// anchor's, instead of its left edge. It does no async work: it is on screen
/// on the first frame after the call, with only a 120 ms fade and scale.
Future<T?> showMenuCard<T>(
  BuildContext context, {
  required Rect anchor,
  required List<MenuCardAction<T>> actions,
  bool alignEnd = false,
  bool highlightAnchor = true,
}) => showGeneralDialog<T>(
  context: context,
  barrierLabel: 'Close menu',
  transitionDuration: const Duration(milliseconds: 120),
  transitionBuilder: (_, animation, _, child) => FadeTransition(
    opacity: animation,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.94, end: 1).animate(animation),
      child: child,
    ),
  ),
  pageBuilder: (dialog, _, _) {
    final scheme = Theme.of(dialog).colorScheme;
    Color on(MenuCardAction<T> a) =>
        a.destructive ? scheme.error : scheme.onSurface;
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(dialog).pop(),
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _DimPainter(highlightAnchor ? anchor : null),
            ),
          ),
        ),
        CustomSingleChildLayout(
          delegate: _CardLayout(
            anchor,
            alignEnd,
            MediaQuery.viewPaddingOf(dialog),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              color: scheme.surfaceContainerHigh,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200, maxWidth: 260),
                child: IntrinsicWidth(
                  child: Column(
                    key: const ValueKey('message-menu'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final a in actions)
                        InkWell(
                          key: ValueKey('menu-${a.keyId}'),
                          onTap: () => Navigator.of(dialog).pop(a.value),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(a.icon, size: 22, color: on(a)),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    a.label,
                                    style: TextStyle(color: on(a)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  },
);

/// Puts the card above the anchor, below it when the top is too tight, and
/// keeps it inside the safe area either way.
class _CardLayout extends SingleChildLayoutDelegate {
  const _CardLayout(this.anchor, this.alignEnd, this.safe);

  final Rect anchor;
  final bool alignEnd;
  final EdgeInsets safe;

  static const _gap = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (alignEnd ? anchor.right - childSize.width : anchor.left)
        .clamp(_gap, math.max(_gap, size.width - childSize.width - _gap))
        .toDouble();
    var y = anchor.top - childSize.height - _gap;
    if (y < safe.top + _gap) y = anchor.bottom + _gap;
    return Offset(
      x,
      y
          .clamp(
            safe.top + _gap,
            math.max(
              safe.top + _gap,
              size.height - safe.bottom - childSize.height - _gap,
            ),
          )
          .toDouble(),
    );
  }

  @override
  bool shouldRelayout(_CardLayout old) =>
      anchor != old.anchor || alignEnd != old.alignEnd || safe != old.safe;
}

/// The dim behind the card. With a [hole] the anchor is cut out of it and
/// casts a soft shadow onto the dim, so it reads as lifted.
class _DimPainter extends CustomPainter {
  const _DimPainter(this.hole);

  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final hole = this.hole;
    if (hole == null) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    final lifted = Path()
      ..addRRect(
        RRect.fromRectAndRadius(hole.inflate(2), const Radius.circular(14)),
      );
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      lifted,
    );
    canvas
      ..drawPath(outside, dim)
      ..save()
      ..clipPath(outside)
      ..drawShadow(lifted, Colors.black, 10, true)
      ..restore();
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole;
}

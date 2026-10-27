import 'package:flutter/material.dart';

/// A fade + grow route (no sideways push): the page grows from [from] (a
/// tile's global rect) or from the centre.
Route<T> fadeScaleRoute<T>({
  required WidgetBuilder builder,
  Rect? from,
  RouteSettings? settings,
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (c, _, _) => builder(c),
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 250),
    opaque: true,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: const Cubic(0.05, 0.7, 0.1, 1.0),
        reverseCurve: Curves.easeInCubic,
      );
      final size = MediaQuery.sizeOf(context);
      final alignment = from == null
          ? Alignment.center
          : Alignment(
              2 * from.center.dx / size.width - 1,
              2 * from.center.dy / size.height - 1,
            );
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: from == null ? 0.92 : 0.3,
            end: 1,
          ).animate(curve),
          alignment: alignment,
          child: child,
        ),
      );
    },
  );
}

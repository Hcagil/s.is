import 'package:flutter/material.dart';

import 'theme.dart';

/// S9: lays a faint white sheen over the top of [child] (a confirmation button),
/// without touching its hit testing.
class Sheen extends StatelessWidget {
  const Sheen({super.key, required this.child, this.radius = 20});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: SisTokens.sheenOpacity),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, 0.5],
      ),
    ),
    child: child,
  );
}

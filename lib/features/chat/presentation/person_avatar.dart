import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../domain/initials.dart';

/// Initials in a circle, tinted per person (seeded by their user id, so they
/// keep one colour everywhere), with the brand dot when [online].
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.label,
    required this.seed,
    this.radius = 24,
    this.online = false,
    this.dotKey,
  });

  final String label;
  final String seed;
  final double radius;
  final bool online;
  final Key? dotKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: personTint(context, seed),
      child: Text(
        initialsOf(label),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: radius * 2 / 3,
          color: personTint(context, seed, ink: true),
        ),
      ),
    );
    if (!online) return avatar;
    final dot = radius * 7 / 12;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            key: dotKey,
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2.5),
            ),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../application/chat_controllers.dart';
import '../domain/initials.dart';

/// Initials in a circle, tinted per person (seeded by their user id, so they
/// keep one colour everywhere), with the brand dot when [online]. Shows the
/// picture at [avatarPath] instead, once it has loaded; still initials while
/// it loads, fails, or there is none.
class PersonAvatar extends ConsumerWidget {
  const PersonAvatar({
    super.key,
    required this.label,
    required this.seed,
    this.radius = 24,
    this.online = false,
    this.dotKey,
    this.avatarPath,
  });

  final String label;
  final String seed;
  final double radius;
  final bool online;
  final Key? dotKey;

  /// Storage path of their picture; null shows the initials.
  final String? avatarPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final path = avatarPath;
    final bytes = path == null
        ? null
        : ref.watch(avatarBytesProvider(path)).value;
    final circle = bytes == null
        ? CircleAvatar(
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
          )
        : ClipOval(
            child: SizedBox(
              width: radius * 2,
              height: radius * 2,
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          );
    if (!online) return circle;
    final dot = radius * 7 / 12;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../application/chat_controllers.dart';

/// Avatar widget for Bacanaks with brand colors.
class BacanaksAvatar extends StatelessWidget {
  /// Creates a BacanaksAvatar.
  const BacanaksAvatar({super.key, this.radius = 18});

  /// Radius of the avatar.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [brand.brand, brand.brandDeep]),
      ),
      child: const Icon(Icons.layers, size: 18, color: Colors.white),
    );
  }
}

/// Waiting indicator for podium command.
class PodiumWaiting extends ConsumerWidget {
  /// Creates a PodiumWaiting.
  const PodiumWaiting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = SisBrand.of(context);
    final last = ref.watch(messagesProvider).value?.lastOrNull;
    if (last == null ||
        last.adminMsg != null ||
        last.body.trim().toLowerCase() != '/podium' ||
        DateTime.now().difference(last.createdAt) >=
            const Duration(minutes: 2)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('podium-waiting'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: brand.theirs,
          borderRadius: BorderRadius.circular(brand.bubbleRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (i) => Container(
              width: 6,
              height: 6,
              margin: EdgeInsets.only(right: i == 2 ? 0 : 4),
              decoration: BoxDecoration(
                color: brand.muted,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

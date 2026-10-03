import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../application/chat_controllers.dart';
import '../domain/group_colors.dart';
import '../domain/initials.dart';

/// The colour of [slot] in a group's name text, for the current theme. The
/// slot comes from the server (see groupColorArgb), so everyone sees the same
/// colour for the same person in the same group.
Color groupColor(BuildContext context, int slot) => Color(
  groupColorArgb(slot, dark: Theme.of(context).brightness == Brightness.dark),
);

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
    this.groupSlot,
  });

  final String label;
  final String seed;
  final double radius;
  final bool online;
  final Key? dotKey;

  /// Storage path of their picture; null shows the initials.
  final String? avatarPath;

  /// Inside a group: the person's colour slot there. The initials placeholder
  /// then wears that colour (tinted background, coloured initials) instead of
  /// the per-person tint. Null everywhere else.
  final int? groupSlot;

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
            backgroundColor: groupSlot == null
                ? personTint(context, seed)
                : groupColor(context, groupSlot!).withValues(alpha: 0.18),
            child: Text(
              initialsOf(label),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: radius * 2 / 3,
                color: groupSlot == null
                    ? personTint(context, seed, ink: true)
                    : groupColor(context, groupSlot!),
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
                cacheWidth:
                    (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                        .round(),
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

/// The small camera badge over an avatar circle, positioned like the brand
/// dot: for editing the picture. [onTap] gets the picture's global rect (the
/// 96 dp circle the badge sits on), where the avatar card opens; it is not
/// called while [busy].
class AvatarEditBadge extends StatelessWidget {
  const AvatarEditBadge({super.key, required this.onTap, this.busy = false});

  final void Function(Rect picture)? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => Positioned(
    right: -2,
    bottom: -2,
    child: GestureDetector(
      onTap: busy || onTap == null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox;
              final r = box.localToGlobal(Offset.zero) & box.size;
              onTap!(
                Rect.fromLTRB(
                  r.right + 2 - 96,
                  r.bottom + 2 - 96,
                  r.right + 2,
                  r.bottom + 2,
                ),
              );
            },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.surface,
            width: 2,
          ),
        ),
        child: const Icon(
          Icons.camera_alt_rounded,
          size: 16,
          color: Colors.white,
        ),
      ),
    ),
  );
}

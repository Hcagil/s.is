import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/appearance_controller.dart';
import '../domain/wallpaper.dart';

/// Paints the chat wallpaper in force (the member's own, else the built-in
/// theme's). Meant as the first child of a Stack, inside Positioned.fill.
class ChatWallpaper extends ConsumerWidget {
  const ChatWallpaper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final w = look.effectiveWallpaper(dark: dark);
    if (w.kind == WallpaperKind.none) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: SizedBox.expand(
          key: const ValueKey('chat-wallpaper'),
          child: _paint(w),
        ),
      ),
    );
  }

  static Widget _paint(Wallpaper w) {
    return switch (w.kind) {
      WallpaperKind.colour => ColoredBox(color: Color(w.colours[0])),
      WallpaperKind.gradient => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [for (final c in w.colours) Color(c)],
          ),
        ),
      ),
      WallpaperKind.picture => Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: Transform.scale(
              scale: 1.08,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: w.blur,
                  sigmaY: w.blur,
                  tileMode: TileMode.decal,
                ),
                enabled: w.blur > 0,
                child: Image.file(
                  File(w.picturePath!),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: w.dim)),
        ],
      ),
      WallpaperKind.none => const SizedBox.shrink(),
    };
  }
}

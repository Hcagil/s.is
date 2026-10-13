import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/sticker.dart';

/// A sticker drawn [size] square: a starter from the app's assets, any other
/// from the (cached) bytes of the sticker store.
class StickerImage extends ConsumerWidget {
  /// Creates a sticker image widget.
  const StickerImage({super.key, required this.stickerId, required this.size});

  /// The ID of the sticker to display.
  final String stickerId;

  /// The size of the sticker image.
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final asset = starterAsset(stickerId);
    final Widget image;
    if (asset != null) {
      image = Image.asset(
        asset,
        key: ValueKey('sticker-image-$stickerId'),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      );
    } else {
      image = ref
          .watch(stickerImageProvider(stickerId))
          .when(
            data: (bytes) => Image.memory(
              bytes,
              key: ValueKey('sticker-image-$stickerId'),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => Tooltip(
              message: l.stickerLoadFailed,
              child: Icon(
                Icons.broken_image_outlined,
                size: size / 3,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Semantics(label: l.stickerLabel, image: true, child: image),
    );
  }
}

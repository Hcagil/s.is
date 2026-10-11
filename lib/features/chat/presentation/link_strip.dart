import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/link_preview_controller.dart';
import '../domain/link_preview.dart';

/// The floating preview strip above the composer: shows the card read for the
/// first link being typed; the X sends the link as plain text.
class LinkStrip extends ConsumerWidget {
  /// Creates a link strip.
  const LinkStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = ref.watch(composerLinkProvider);
    if (card == null) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = card.draft.preview;
    final image = card.draft.image;

    return Container(
      key: const ValueKey('link-strip'),
      margin: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      padding: const EdgeInsets.fromLTRB(8, 8, 2, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 44,
              child: image == null
                  ? ColoredBox(
                      color: scheme.primary.withValues(alpha: 0.12),
                      child: Icon(Icons.link, color: scheme.primary),
                    )
                  : Image.memory(
                      image,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  preview.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  _domain(preview.url),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('link-strip-dismiss'),
            tooltip: l.composerLinkRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => ref.read(composerLinkProvider.notifier).dismiss(),
          ),
        ],
      ),
    );
  }
}

String _domain(Uri url) {
  final h = displayHost(url);
  return h.startsWith('www.') ? h.substring(4) : h;
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/link_preview_controller.dart';
import '../domain/link_preview.dart';
import '../domain/message.dart';

/// The card under a link message: picture, title, description and domain.
/// Tapping it opens the link outside the app; nothing opens by itself.
class LinkCard extends ConsumerWidget {
  /// Creates a link card.
  const LinkCard({
    super.key,
    required this.message,
    required this.ink,
    required this.width,
  });

  /// The message carrying the card.
  final Message message;

  /// The bubble's text colour; the card is tinted from it.
  final Color ink;

  /// The bubble's content width.
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = message.linkPreview;
    if (preview == null) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final path = preview.imagePath;
    final bytes = path == null
        ? null
        : ref.watch(linkImageProvider(path)).value;

    return Semantics(
      button: true,
      label: l.linkCardOpen,
      child: SizedBox(
        width: width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Material(
            color: ink.withValues(alpha: 0.08),
            child: InkWell(
              key: ValueKey('link-card-${message.id}'),
              onTap: () => _open(context, ref, preview.url),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (path != null)
                    SizedBox(
                      height: 150,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          bytes == null
                              ? ColoredBox(color: ink.withValues(alpha: 0.06))
                              : Image.memory(
                                  bytes,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                ),
                          if (preview.video)
                            const Center(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          preview.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: ink,
                          ),
                        ),
                        if (preview.description != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              preview.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: ink.withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _domain(preview.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: ink.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, Uri url) async {
    final opened = await ref.read(linkOpenerProvider).open(url);
    if (!opened && context.mounted) {
      showSisNotice(
        context,
        AppLocalizations.of(context).linkOpenFailed(_domain(url)),
        isError: true,
      );
    }
  }
}

String _domain(Uri url) {
  final h = displayHost(url);
  return h.startsWith('www.') ? h.substring(4) : h;
}

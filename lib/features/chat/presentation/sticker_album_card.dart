import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import 'sticker_albums.dart';
import 'sticker_image.dart';

/// A card widget displaying a sticker album from a message.
class StickerAlbumCard extends ConsumerWidget {
  /// Creates a [StickerAlbumCard].
  const StickerAlbumCard({
    super.key,
    required this.message,
    required this.mine,
    required this.time,
  });

  /// The message containing the sticker album info.
  final Message message;

  /// Whether the message is from the current user.
  final bool mine;

  /// The time widget to display.
  final Widget time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    final albumId = message.albumId;
    final AsyncValue<List<String>>? stickers = albumId == null
        ? null
        : ref.watch(albumStickersProvider(albumId));
    final ids = stickers?.value;
    final gone = albumId == null || (stickers != null && stickers.hasError);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: albumId == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => StickerAlbumPreviewPage(
                  albumId: albumId,
                  name: message.body,
                  mine: mine,
                ),
              ),
            ),
      child: Container(
        key: ValueKey('album-card-${message.id}'),
        width: 238,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: brand.surfaceHigh,
          borderRadius: BorderRadius.circular(brand.bubbleRadius),
          border: Border.all(color: brand.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 92,
              height: 92,
              child: ids == null
                  ? null
                  : Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 2,
                      runSpacing: 2,
                      children: [
                        for (final id in ids.take(4))
                          StickerImage(stickerId: id, size: 44),
                      ],
                    ),
            ),
            Text(
              message.body,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (gone)
              Text(
                l.stickerAlbumGone,
                style: TextStyle(fontSize: 12, color: brand.muted),
              )
            else if (ids != null)
              Text(
                l.stickerAlbumStickers(ids.length),
                style: TextStyle(fontSize: 12, color: brand.muted),
              ),
            if (!mine && ids != null && albumId != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _Tool(
                      key: ValueKey('album-add-${message.id}'),
                      label: l.stickerAlbumAdd,
                      onTap: () => _run(
                        context,
                        () => ref
                            .read(stickerLibraryProvider.notifier)
                            .addSharedAlbum(albumId),
                        l.stickerAlbumAdded,
                      ),
                    ),
                    _Tool(
                      key: ValueKey('album-fav-${message.id}'),
                      label: l.stickerAlbumAddFavourites,
                      onTap: () => _run(
                        context,
                        () => ref
                            .read(stickerLibraryProvider.notifier)
                            .addSharedAlbumToFavourites(albumId),
                        l.stickerAlbumFavouritesAdded,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(alignment: Alignment.centerRight, child: time),
            ),
          ],
        ),
      ),
    );
  }
}

/// A page showing the preview of a sticker album.
class StickerAlbumPreviewPage extends ConsumerWidget {
  /// Creates a [StickerAlbumPreviewPage].
  const StickerAlbumPreviewPage({
    super.key,
    required this.albumId,
    required this.name,
    required this.mine,
  });

  /// The ID of the album.
  final String albumId;

  /// The name of the album.
  final String name;

  /// Whether the album is owned by the current user.
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final stickers = ref.watch(albumStickersProvider(albumId));

    return Scaffold(
      key: const ValueKey('album-preview-page'),
      appBar: AppBar(title: Text(name)),
      body: stickers.when(
        data: (ids) => GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: ids.length,
          itemBuilder: (_, i) => StickerImage(stickerId: ids[i], size: 72),
        ),
        loading: () => const SizedBox.shrink(),
        error: (_, _) => Center(child: Text(l.stickerAlbumGone)),
      ),
      bottomNavigationBar: (!mine && stickers.hasValue)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('album-preview-add'),
                        onPressed: () => _run(
                          context,
                          () => ref
                              .read(stickerLibraryProvider.notifier)
                              .addSharedAlbum(albumId),
                          l.stickerAlbumAdded,
                          close: true,
                        ),
                        child: Text(l.stickerAlbumAdd),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('album-preview-fav'),
                        onPressed: () => _run(
                          context,
                          () => ref
                              .read(stickerLibraryProvider.notifier)
                              .addSharedAlbumToFavourites(albumId),
                          l.stickerAlbumFavouritesAdded,
                          close: true,
                        ),
                        child: Text(l.stickerAlbumAddFavourites),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return Material(
      color: brand.brand.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: brand.brand,
            ),
          ),
        ),
      ),
    );
  }
}

/// Runs [job], shows its failure or [okText], and with [close] leaves the page.
Future<void> _run(
  BuildContext context,
  Future<Failure?> Function() job,
  String okText, {
  bool close = false,
}) async {
  final failure = await job();
  if (!context.mounted) return;
  final l = AppLocalizations.of(context);
  if (failure != null) {
    showSisNotice(context, stickerFailureText(l, failure), isError: true);
    return;
  }
  showSisNotice(context, okText);
  if (close) Navigator.of(context).pop();
}

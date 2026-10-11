import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import '../domain/sticker.dart';
import 'message_menu_card.dart';
import 'sticker_albums.dart';
import 'sticker_image.dart';

/// A page displaying the stickers of one of the member's own albums.
class StickerAlbumPage extends ConsumerWidget {
  /// Creates a [StickerAlbumPage] for the given [albumId] and [conversationId].
  const StickerAlbumPage({
    super.key,
    required this.albumId,
    required this.conversationId,
  });

  /// The ID of the sticker album to display.
  final String albumId;

  /// The ID of the conversation to send stickers to.
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final album = ref
        .watch(stickerLibraryProvider)
        .albums
        .where((a) => a.id == albumId)
        .firstOrNull;

    if (album == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l.stickerAlbumGone)),
      );
    }

    return Scaffold(
      key: const ValueKey('sticker-album-page'),
      appBar: AppBar(
        title: Text(album.name),
        actions: [
          Builder(
            builder: (btn) => IconButton(
              key: const ValueKey('sticker-album-menu'),
              icon: const Icon(Icons.more_vert),
              onPressed: () => _menu(btn, ref, album),
            ),
          ),
        ],
      ),
      body: album.stickerIds.isEmpty
          ? Center(child: Text(l.stickerEmptyAlbum))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: album.stickerIds.length,
              itemBuilder: (cell, i) {
                final id = album.stickerIds[i];
                return GestureDetector(
                  key: ValueKey('album-sticker-$id'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    ref
                        .read(sendQueueProvider.notifier)
                        .enqueueSticker(
                          conversationId,
                          id,
                          replyTo: ref.read(replyingToProvider),
                        );
                    ref.read(stickerLibraryProvider.notifier).markUsed(id);
                    Navigator.of(cell).pop();
                  },
                  onLongPress: () => _remove(cell, ref, album.id, id),
                  child: StickerImage(stickerId: id, size: 72),
                );
              },
            ),
    );
  }

  Rect _rectOf(BuildContext c) {
    final box = c.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _remove(
    BuildContext cell,
    WidgetRef ref,
    String albumId,
    String stickerId,
  ) async {
    final l = AppLocalizations.of(cell);
    final picked = await showMenuCard<bool>(
      cell,
      anchor: _rectOf(cell),
      cardKey: const ValueKey('sticker-album-item-menu'),
      actions: [
        MenuCardAction<bool>(
          value: true,
          keyId: 'remove-from-album',
          icon: Icons.remove_circle_outline,
          label: l.stickerRemoveFromAlbum,
          destructive: true,
        ),
      ],
    );
    if (picked != true) return;
    final failure = await ref
        .read(stickerLibraryProvider.notifier)
        .removeFromAlbum(albumId, stickerId);
    if (failure != null && cell.mounted) {
      showSisNotice(cell, stickerFailureText(l, failure), isError: true);
    }
  }

  Future<void> _menu(
    BuildContext btn,
    WidgetRef ref,
    StickerAlbum album,
  ) async {
    final l = AppLocalizations.of(btn);
    final picked = await showMenuCard<String>(
      btn,
      anchor: _rectOf(btn),
      alignEnd: true,
      below: true,
      cardKey: const ValueKey('sticker-album-menu-card'),
      actions: [
        MenuCardAction<String>(
          value: 'share',
          keyId: 'album-share',
          icon: Icons.share_outlined,
          label: l.stickerAlbumShare,
        ),
        MenuCardAction<String>(
          value: 'rename',
          keyId: 'album-rename',
          icon: Icons.edit_outlined,
          label: l.stickerAlbumRename,
        ),
        MenuCardAction<String>(
          value: 'delete',
          keyId: 'album-delete',
          icon: Icons.delete_outline,
          label: l.stickerAlbumDelete,
          destructive: true,
        ),
      ],
    );
    if (!btn.mounted) return;

    switch (picked) {
      case 'share':
        ref
            .read(sendQueueProvider.notifier)
            .enqueueStickerAlbum(conversationId, album.id, album.name);
        showSisNotice(btn, l.stickerAlbumShared);
      case 'rename':
        final name = await showAlbumNameCard(
          btn,
          initial: album.name,
          title: l.stickerAlbumRenameTitle,
          action: l.stickerAlbumRename,
        );
        if (name == null || !btn.mounted) return;
        final f = await ref
            .read(stickerLibraryProvider.notifier)
            .renameAlbum(album.id, name);
        if (f != null && btn.mounted) {
          showSisNotice(btn, stickerFailureText(l, f), isError: true);
        }
      case 'delete':
        final ok = await showDialog<bool>(
          context: btn,
          builder: (d) => AlertDialog(
            key: const ValueKey('album-delete-dialog'),
            title: Text(l.stickerAlbumDeleteTitle),
            content: Text(l.stickerAlbumDeleteBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(d).pop(false),
                child: Text(l.stickerCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(d).pop(true),
                child: Text(l.stickerDelete),
              ),
            ],
          ),
        );
        if (ok != true || !btn.mounted) return;
        final f = await ref
            .read(stickerLibraryProvider.notifier)
            .deleteAlbum(album.id);
        if (!btn.mounted) return;
        if (f != null) {
          showSisNotice(btn, stickerFailureText(l, f), isError: true);
        } else {
          Navigator.of(btn).pop();
        }
    }
  }
}

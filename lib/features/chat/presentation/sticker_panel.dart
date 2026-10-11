import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import '../domain/sticker.dart';
import 'message_menu_card.dart';
import 'sticker_album_page.dart';
import 'sticker_albums.dart';
import 'sticker_create_page.dart';
import 'sticker_image.dart';

/// A panel for selecting and sending stickers in a conversation.
class StickerPanel extends ConsumerStatefulWidget {
  /// Creates a sticker panel for the given conversation.
  const StickerPanel({super.key, required this.conversationId});

  /// The ID of the conversation this panel is associated with.
  final String conversationId;

  @override
  ConsumerState<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends ConsumerState<StickerPanel> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    final lib = ref.watch(stickerLibraryProvider);
    final l = AppLocalizations.of(context);

    return Container(
      key: const ValueKey('sticker-panel'),
      height: 250,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: brand.surfaceHigh,
        borderRadius: BorderRadius.circular(brand.bubbleRadius),
        border: Border.all(color: brand.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _buildTab(0, l.stickerTabRecent),
                _buildTab(1, l.stickerTabFavourites),
                _buildTab(2, l.stickerTabStarter),
                _buildTab(3, l.stickerTabMine),
                _buildTab(4, l.stickerTabNew),
              ],
            ),
          ),
          Expanded(child: _buildBody(lib, l)),
        ],
      ),
    );
  }

  Widget _buildTab(int index, String label) {
    final brand = SisBrand.of(context);
    final selected = _tab == index;

    return GestureDetector(
      key: ValueKey('sticker-tab-$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (index < 4) {
          setState(() => _tab = index);
        } else {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const StickerCreatePage()),
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? brand.brand.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? brand.brand : brand.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(StickerLibrary lib, AppLocalizations l) {
    switch (_tab) {
      case 0:
        return _grid(lib.recent, l.stickerEmptyRecent);
      case 1:
        return _grid(lib.favourites, l.stickerEmptyFavourites, removable: true);
      case 2:
        return _grid(starterStickerIds, '');
      default:
        return _albums(lib, l);
    }
  }

  Widget _grid(List<String> ids, String empty, {bool removable = false}) {
    final brand = SisBrand.of(context);

    if (ids.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            empty,
            textAlign: TextAlign.center,
            style: TextStyle(color: brand.muted),
          ),
        ),
      );
    }

    return GridView.builder(
      key: ValueKey('sticker-grid-$_tab'),
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: ids.length,
      itemBuilder: (cell, i) {
        final id = ids[i];
        return GestureDetector(
          key: ValueKey('panel-sticker-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _send(id),
          onLongPress: removable ? () => _removeFavourite(cell, id) : null,
          child: StickerImage(stickerId: id, size: 64),
        );
      },
    );
  }

  void _send(String id) {
    ref
        .read(sendQueueProvider.notifier)
        .enqueueSticker(
          widget.conversationId,
          id,
          replyTo: ref.read(replyingToProvider),
        );
    ref.read(stickerLibraryProvider.notifier).markUsed(id);
  }

  Future<void> _removeFavourite(BuildContext cell, String id) async {
    final box = cell.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final l = AppLocalizations.of(context);

    final picked = await showMenuCard<bool>(
      cell,
      anchor: anchor,
      cardKey: const ValueKey('sticker-fav-menu'),
      actions: [
        MenuCardAction<bool>(
          value: true,
          keyId: 'remove-favourite',
          icon: Icons.remove_circle_outline,
          label: l.stickerRemoveFavourite,
          destructive: true,
        ),
      ],
    );
    if (picked != true) return;

    final f = await ref
        .read(stickerLibraryProvider.notifier)
        .removeFavourite(id);
    if (f != null && mounted) {
      showSisNotice(context, stickerFailureText(l, f), isError: true);
    }
  }

  Widget _albums(StickerLibrary lib, AppLocalizations l) {
    final brand = SisBrand.of(context);

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        key: const ValueKey('sticker-albums-list'),
        padding: const EdgeInsets.all(8),
        children: [
          for (final a in lib.albums)
            ListTile(
              key: ValueKey('panel-album-${a.id}'),
              dense: true,
              leading: a.stickerIds.isNotEmpty
                  ? StickerImage(stickerId: a.stickerIds.first, size: 40)
                  : const Icon(Icons.photo_album_outlined),
              title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                l.stickerAlbumsCount(a.stickerIds.length, maxAlbumStickers),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StickerAlbumPage(
                    albumId: a.id,
                    conversationId: widget.conversationId,
                  ),
                ),
              ),
            ),
          if (lib.albums.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l.stickerNoAlbums,
                style: TextStyle(color: brand.muted),
              ),
            ),
          ListTile(
            key: const ValueKey('panel-album-new'),
            dense: true,
            leading: const Icon(Icons.add),
            title: Text(l.stickerNewAlbum),
            subtitle: Text(
              l.stickerAlbumsCount(lib.albums.length, maxStickerAlbums),
            ),
            onTap: _newAlbum,
          ),
        ],
      ),
    );
  }

  Future<void> _newAlbum() async {
    final l = AppLocalizations.of(context);
    final name = await showAlbumNameCard(
      context,
      title: l.stickerNewAlbum,
      action: l.stickerAlbumCreate,
    );
    if (name == null || !mounted) return;

    final made = await ref
        .read(stickerLibraryProvider.notifier)
        .createAlbum(name);
    final failed = made.failure;
    if (failed != null && mounted) {
      showSisNotice(context, stickerFailureText(l, failed), isError: true);
    }
  }
}

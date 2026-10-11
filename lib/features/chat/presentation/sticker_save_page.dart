import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/sticker.dart';
import 'sticker_albums.dart';
import 'sticker_draft.dart';
import 'sticker_painter.dart';

/// Page for saving a sticker to an album or as a favourite.
class StickerSavePage extends ConsumerStatefulWidget {
  /// Creates a new sticker save page with the given draft.
  const StickerSavePage({super.key, required this.draft});

  /// The sticker draft to save.
  final StickerDraft draft;

  @override
  ConsumerState<StickerSavePage> createState() => _StickerSavePageState();
}

class _StickerSavePageState extends ConsumerState<StickerSavePage> {
  String? _albumId;
  bool _fav = false;
  bool _saving = false;
  String? _savedName;
  bool _preselected = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final lib = ref.watch(stickerLibraryProvider);

    if (!_preselected && widget.draft.entryAlbumId != null && lib.loaded) {
      final a = lib.albums
          .where(
            (a) =>
                a.id == widget.draft.entryAlbumId &&
                a.stickerIds.length < maxAlbumStickers,
          )
          .firstOrNull;
      if (a != null) _albumId = a.id;
      _preselected = true;
    }

    if (_albumId != null && !lib.albums.any((a) => a.id == _albumId)) {
      _albumId = null;
    }

    final atMax = lib.albums.length >= maxStickerAlbums;

    return Scaffold(
      key: const ValueKey('sticker-save-page'),
      appBar: AppBar(title: Text(l.makerSaveTitle)),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: CustomPaint(
                  painter: StickerPainter(
                    widget.draft,
                    cut: widget.draft.cutOut && widget.draft.hasCutOut ? 1 : 0,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: 16),
          if (_savedName != null)
            _saved(l)
          else ...[
            Text(l.makerSaveToCount(lib.albums.length, maxStickerAlbums)),
            SizedBox(height: 8),
            for (final a in lib.albums)
              _row(
                key: ValueKey('maker-album-${a.id}'),
                icon: a.id == _albumId
                    ? Icons.check
                    : Icons.photo_album_outlined,
                label: a.name,
                trailing: a.stickerIds.length >= maxAlbumStickers
                    ? l.makerFull
                    : l.makerCountOf(a.stickerIds.length, maxAlbumStickers),
                enabled: !(a.stickerIds.length >= maxAlbumStickers) && !_saving,
                selected: a.id == _albumId,
                onTap: () => setState(() => _albumId = a.id),
              ),
            _row(
              key: ValueKey('maker-new-album'),
              icon: Icons.add,
              label: l.stickerNewAlbum,
              trailing: atMax ? l.makerLimitReached : null,
              enabled: !atMax && !_saving,
              onTap: _newAlbum,
            ),
            _row(
              key: ValueKey('maker-fav'),
              icon: Icons.star_outline,
              label: l.makerAlsoFavourite,
              trailing: l.makerCountOf(
                lib.favourites.length,
                maxFavouriteStickers,
              ),
              enabled: lib.favourites.length < maxFavouriteStickers && !_saving,
              selected: _fav,
              onTap: () => setState(() => _fav = !_fav),
            ),
            SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: ValueKey('maker-save'),
                onPressed: _albumId == null || _saving
                    ? null
                    : () => _save(lib),
                child: Text(l.makerSave),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row({
    required Key key,
    required IconData icon,
    required String label,
    String? trailing,
    required bool enabled,
    bool selected = false,
    required VoidCallback onTap,
  }) {
    final brand = SisBrand.of(context);
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Container(
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: brand.surfaceHigh,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? brand.brand : brand.line),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: selected ? brand.brand : null),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing,
                    style: TextStyle(color: brand.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _saved(AppLocalizations l) {
    final brand = SisBrand.of(context);
    return Column(
      children: [
        Icon(Icons.check_circle_outline, size: 36, color: brand.brand),
        SizedBox(height: 8),
        Text(
          l.makerSavedTo(_savedName!),
          key: ValueKey('maker-saved'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: ValueKey('maker-done'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.makerDone),
          ),
        ),
      ],
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
    if (!mounted) return;
    final failed = made.failure;
    if (failed != null) {
      showSisNotice(context, stickerFailureText(l, failed), isError: true);
      return;
    }
    if (made.id != null) setState(() => _albumId = made.id);
  }

  Future<void> _save(StickerLibrary lib) async {
    final l = AppLocalizations.of(context);
    final id = _albumId;
    if (id == null) return;
    setState(() => _saving = true);
    final rgba = await renderStickerRgba(widget.draft);
    if (!mounted) return;
    Failure? failure;
    if (rgba == null) {
      failure = const StickerMakeFailure();
    } else {
      failure = await ref
          .read(stickerLibraryProvider.notifier)
          .saveMade(rgba, albumId: id, favourite: _fav);
    }
    if (!mounted) return;
    if (failure != null) {
      setState(() => _saving = false);
      showSisNotice(
        context,
        failure is StickerLimitFailure
            ? stickerFailureText(l, failure)
            : l.makerSaveFailed,
        isError: true,
      );
      return;
    }
    final name =
        ref
            .read(stickerLibraryProvider)
            .albums
            .where((a) => a.id == id)
            .map((a) => a.name)
            .firstOrNull ??
        '';
    setState(() {
      _saving = false;
      _savedName = name;
    });
  }
}

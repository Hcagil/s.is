import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/swipe_back.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/gallery.dart';
import 'attachment_sheet.dart';
import 'crop_screen.dart';

/// Opens the sticker gallery page; null when the member backs out.
Future<PickedImage?> pickStickerPhoto(BuildContext context) =>
    Navigator.of(context).push<PickedImage?>(
      MaterialPageRoute(
        settings: noSwipeBack,
        builder: (_) => const StickerGalleryPage(),
      ),
    );

/// A full-page photo picker for the sticker maker.
class StickerGalleryPage extends ConsumerStatefulWidget {
  /// Creates the sticker gallery page.
  const StickerGalleryPage({super.key});

  @override
  ConsumerState<StickerGalleryPage> createState() => _StickerGalleryPageState();
}

class _StickerGalleryPageState extends ConsumerState<StickerGalleryPage> {
  GalleryAccess? _access;
  List<GalleryPhoto> _photos = const [];
  bool _loading = true;
  bool _opening = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextPage = 0;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final g = ref.read(galleryProvider);
    final access = await g.requestAccess();
    final photos =
        access == GalleryAccess.full || access == GalleryAccess.limited
        ? await g.recent(count: 60)
        : const <GalleryPhoto>[];
    if (!mounted) return;
    setState(() {
      _access = access;
      _photos = photos;
      _loading = false;
      _nextPage = 1;
      _hasMore = photos.length == 60;
    });
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading || !_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(galleryProvider)
          .recent(page: _nextPage, count: 60);
      if (!mounted) return;
      setState(() {
        _photos = [..._photos, ...page];
        _nextPage++;
        _hasMore = page.length == 60;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _choose(GalleryPhoto p) async {
    if (_opening) return;
    setState(() => _opening = true);
    final image = await ref.read(galleryProvider).loadForCrop(p);
    if (!mounted) return;
    if (image == null) {
      setState(() => _opening = false);
      return;
    }
    final cropped = await openCropScreen(context, image);
    if (!mounted) return;
    if (cropped == null) {
      setState(() => _opening = false);
      return;
    }
    Navigator.of(context).pop(cropped);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final denied =
        _access == GalleryAccess.denied ||
        _access == GalleryAccess.permanentlyDenied;
    return Scaffold(
      key: const ValueKey('sticker-gallery-page'),
      appBar: AppBar(title: Text(l.makerGalleryTitle)),
      body: _loading
          ? const SizedBox.shrink()
          : denied
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l.attachFasterBody,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  FilledButton(
                    key: const ValueKey('sticker-gallery-allow'),
                    onPressed: _access == GalleryAccess.permanentlyDenied
                        ? () => ref.read(galleryProvider).openSettings()
                        : () {
                            setState(() => _loading = true);
                            _load();
                          },
                    child: Text(
                      _access == GalleryAccess.permanentlyDenied
                          ? l.attachOpenSettings
                          : l.attachAllowPhotos,
                    ),
                  ),
                ],
              ),
            )
          : _photos.isEmpty
          ? Center(child: Text(l.attachNoPhotos))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Text(
                    l.makerRecent,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.zero,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 3,
                          crossAxisSpacing: 3,
                        ),
                    itemCount: _photos.length,
                    itemBuilder: (c, i) {
                      final p = _photos[i];
                      return GalleryThumb(
                        key: ValueKey('sticker-gallery-photo-${p.id}'),
                        photo: p,
                        onTap: () => _choose(p),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

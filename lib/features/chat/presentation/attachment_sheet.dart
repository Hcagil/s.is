import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/external_picker.dart';
import '../domain/gallery.dart';
import 'crop_screen.dart';

/// Shows the attachment sheet; an empty `images` list when the member
/// closes it or backs out without choosing a photo. `dropped` is how many
/// more photos "From an app" offered beyond the cap -- 0 unless it was hit.
/// With [square] the sheet crops the chosen photo itself (the crop screen
/// opens over the grid, so back returns to it) and returns the cropped image.
Future<({List<PickedImage> images, int dropped})> showAttachmentSheet(
  BuildContext context, {
  bool square = false,
}) async {
  final result =
      await showModalBottomSheet<({List<PickedImage> images, int dropped})>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => AttachmentSheet(square: square),
      );
  return result ?? (images: const <PickedImage>[], dropped: 0);
}

/// What the paperclip's small menu offers.
enum AttachSource { camera, library }

/// The paperclip's small menu: take a photo now, or pick from the photo
/// library. Null when dismissed.
Future<AttachSource?> showAttachMenu(BuildContext context) =>
    showModalBottomSheet<AttachSource>(
      context: context,
      showDragHandle: true,
      // The paperclip leaves the keyboard up: the sheet must not take focus.
      requestFocus: false,
      builder: (sheet) => SafeArea(
        child: Column(
          key: const ValueKey('attach-menu'),
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('attach-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.of(sheet).pop(AttachSource.camera),
            ),
            ListTile(
              key: const ValueKey('attach-library'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.of(sheet).pop(AttachSource.library),
            ),
          ],
        ),
      ),
    );

/// The phone's recent photos to send from. Asks for photo access the first
/// time it opens; when access is missing or partial, shows SIS's own screen
/// for it instead of the phone's photos.
class AttachmentSheet extends ConsumerStatefulWidget {
  const AttachmentSheet({super.key, this.square = false});

  /// True when picking a profile/group picture: the chosen photo is loaded
  /// uncropped, ready for the crop screen, instead of the long-edge resize
  /// used for a chat photo.
  final bool square;

  @override
  ConsumerState<AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends ConsumerState<AttachmentSheet> {
  static const _pageSize = 60;
  // Trigger the next page this many pixels before the grid's physical end,
  // so the page is ready before the member reaches it.
  static const _loadMoreThreshold = 600.0;

  GalleryAccess? _access;
  List<GalleryPhoto> _photos = const [];
  bool _loading = true;
  bool _opening = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextPage = 0;
  // Bumped by every _load(); a _loadMore() in flight when a reload starts
  // discards its own stale result instead of appending it onto page 0.
  int _generation = 0;
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

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreThreshold) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final gallery = ref.read(galleryProvider);
    final access = await gallery.requestAccess();
    final photos =
        access == GalleryAccess.full || access == GalleryAccess.limited
        ? await gallery.recent(count: _pageSize)
        : const <GalleryPhoto>[];
    if (!mounted || generation != _generation) return;
    setState(() {
      _access = access;
      _photos = photos;
      _loading = false;
      _nextPage = 1;
      _hasMore = photos.length == _pageSize;
      // A page still in flight from the old generation never clears this
      // itself (it returns early above), so the reload owns the reset.
      _loadingMore = false;
    });
  }

  Future<void> _loadMore() async {
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(galleryProvider)
          .recent(page: _nextPage, count: _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        _photos = [..._photos, ...page];
        _nextPage++;
        _hasMore = page.length == _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
      showSisNotice(context, 'Could not load more photos.', isError: true);
    }
  }

  Future<void> _choose(GalleryPhoto p) async {
    if (_opening) return;
    setState(() => _opening = true);
    PickedImage? image;
    try {
      image = widget.square
          ? await ref.read(galleryProvider).loadForCrop(p)
          : await ref.read(galleryProvider).load(p);
    } catch (_) {
      image = null; // a thrown load is a failed load, never a stuck sheet
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (image == null) {
      showSisNotice(context, 'That photo could not be opened.', isError: true);
      return;
    }
    await _finish([image], 0);
  }

  Future<void> _selectMore() async {
    await ref.read(galleryProvider).selectMore();
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  /// Hands photo selection to another app on the phone. [widget.square]
  /// asks for exactly one photo (a picture); otherwise as many as the
  /// chosen app allows.
  Future<void> _fromApp() async {
    if (_opening) return;
    setState(() => _opening = true);
    final picker = ref.read(externalPickerProvider);
    final result = widget.square
        ? await picker.pickProfilePicture()
        : await picker.pickAttachments();
    if (!mounted) return;
    setState(() => _opening = false);
    switch (result) {
      case ExternalPickedImages(:final images, :final dropped)
          when images.isNotEmpty:
        await _finish(images, dropped);
      case ExternalPickCancelled():
        return;
      case ExternalPickedImages() || ExternalPickFailed():
        showSisNotice(context, 'That could not be opened.', isError: true);
    }
  }

  /// Ends the pick. A chat photo closes the sheet. A picture is cropped
  /// first, with the crop screen pushed over this sheet: backing out of it
  /// returns to the grid at the same scroll position, and only a finished
  /// crop closes the sheet.
  Future<void> _finish(List<PickedImage> images, int dropped) async {
    if (!widget.square) {
      Navigator.of(context).pop((images: images, dropped: dropped));
      return;
    }
    final cropped = await openCropScreen(context, images.first);
    if (!mounted || cropped == null) return;
    Navigator.of(context).pop((images: [cropped], dropped: 0));
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.6;
    if (_loading) {
      return SizedBox(
        height: height,
        child: const Center(child: SisLoadingLogo()),
      );
    }
    if (_access == GalleryAccess.denied ||
        _access == GalleryAccess.permanentlyDenied) {
      return SizedBox(
        height: height,
        child: _PhotoAccessRequest(
          permanentlyDenied: _access == GalleryAccess.permanentlyDenied,
          onAllow: () {
            setState(() => _loading = true);
            _load();
          },
          onOpenSettings: () => ref.read(galleryProvider).openSettings(),
          onFromApp: _fromApp,
          onNotNow: () => Navigator.of(context).pop(),
        ),
      );
    }

    final limited = _access == GalleryAccess.limited;
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Photos',
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (limited)
            TextButton(
              key: const ValueKey('sheet-allow-more'),
              onPressed: _selectMore,
              child: const Text('Allow more'),
            ),
          IconButton(
            key: const ValueKey('sheet-from-app'),
            onPressed: _fromApp,
            icon: const Icon(Icons.apps_rounded),
            tooltip: 'From an app',
          ),
        ],
      ),
    );

    final Widget body = _photos.isEmpty
        ? const Center(child: Text('No photos yet'))
        : GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: _photos.length,
            itemBuilder: (context, i) {
              final p = _photos[i];
              return _Thumb(
                key: ValueKey('sheet-photo-${p.id}'),
                photo: p,
                onTap: () => _choose(p),
              );
            },
          );

    return SizedBox(
      height: height,
      child: Column(
        children: [
          header,
          Expanded(child: body),
          SizedBox(
            height: 3,
            child: _loadingMore ? const SisProgressLine() : null,
          ),
        ],
      ),
    );
  }
}

/// SIS's own screen for asking gallery access: shown instead of the grid
/// when access is denied, or opens the app's settings page when a previous
/// ask was already refused (the system will not prompt again).
class _PhotoAccessRequest extends StatelessWidget {
  const _PhotoAccessRequest({
    required this.permanentlyDenied,
    required this.onAllow,
    required this.onOpenSettings,
    required this.onNotNow,
    required this.onFromApp,
  });

  final bool permanentlyDenied;
  final VoidCallback onAllow;
  final VoidCallback onOpenSettings;
  final VoidCallback onNotNow;
  final VoidCallback onFromApp;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    // A short phone (360x640 dp and smaller) cannot fit the icon, both
    // lines of text and both buttons at once; scroll rather than clip --
    // the buttons must always be reachable, never cut off.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: t.surfaceHigh,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(Icons.image_rounded, size: 48, color: t.brand),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Send photos faster',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Allow access so your gallery loads right here – '
                    'nothing is uploaded until you send it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('sheet-allow'),
                      onPressed: permanentlyDenied ? onOpenSettings : onAllow,
                      child: Text(
                        permanentlyDenied ? 'Open settings' : 'Allow photos',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('sheet-from-app'),
                    onPressed: onFromApp,
                    icon: const Icon(Icons.apps_rounded, size: 18),
                    label: const Text('From an app'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('sheet-not-now'),
                    onPressed: onNotNow,
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends ConsumerStatefulWidget {
  const _Thumb({super.key, required this.photo, required this.onTap});

  final GalleryPhoto photo;
  final VoidCallback onTap;

  @override
  ConsumerState<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends ConsumerState<_Thumb> {
  // Asked once: rebuilding the grid must not refetch every thumbnail.
  late final Future<Uint8List?> _bytes = ref
      .read(galleryProvider)
      .thumbnail(widget.photo);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) => InkWell(
        onTap: widget.onTap,
        child: switch (snapshot.data) {
          final Uint8List data => Image.memory(
            data,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
          // Not read yet, or unreadable: a quiet tile, but still tappable (a
          // limited-access photo can be slow, and a tap must never be lost).
          null => ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
          ),
        },
      ),
    );
  }
}

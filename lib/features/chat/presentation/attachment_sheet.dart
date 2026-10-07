import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/grey_option.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/external_picker.dart';
import '../domain/gallery.dart';
import 'crop_screen.dart';
import 'message_menu_card.dart';
import 'person_avatar.dart';

/// Shows the paperclip's photo grid; an empty `images` list when the member
/// closes it or backs out without choosing a photo. `dropped` is how many
/// more photos "Gallery" offered beyond the cap -- 0 unless it was hit. A chat
/// photo is not sent from here: the caller opens the preview page with the
/// returned photos.
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
        // The paperclip leaves the keyboard up: the panel must not take focus.
        requestFocus: false,
        builder: (_) => AttachmentSheet(square: square),
      );
  return result ?? (images: const <PickedImage>[], dropped: 0);
}

/// Opens the attach card above [anchor] (the paperclip's global rect). The
/// result is 'photo' or 'poll' for the tile tapped, null when closed without
/// choosing. Photo and Poll are live, the other tiles are greyed.
Future<String?> showAttachMenu(BuildContext context, {required Rect anchor}) =>
    showFloatingCard<String>(
      context,
      anchor: anchor,
      cardKey: const ValueKey('attach-menu'),
      child: const _AttachMenu(),
    );

class _AttachMenu extends StatelessWidget {
  const _AttachMenu();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 6,
        runSpacing: 14,
        children: [
          InkWell(
            key: const ValueKey('attach-photo'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).pop('photo'),
            child: _attachTile(
              context,
              slot: 0,
              icon: Icons.photo_outlined,
              label: l.attachPhoto,
            ),
          ),
          GreyOption(
            name: 'att_tvideo',
            child: _attachTile(
              context,
              slot: 1,
              icon: Icons.videocam_outlined,
              label: l.attachVideo,
            ),
          ),
          GreyOption(
            name: 'att_tfile',
            child: _attachTile(
              context,
              slot: 2,
              icon: Icons.insert_drive_file_outlined,
              label: l.attachFile,
            ),
          ),
          GreyOption(
            name: 'att_tvoice',
            child: _attachTile(
              context,
              slot: 3,
              icon: Icons.mic_none_rounded,
              label: l.attachVoice,
            ),
          ),
          GreyOption(
            name: 'att_tloc',
            child: _attachTile(
              context,
              slot: 4,
              icon: Icons.location_on_outlined,
              label: l.attachLocation,
            ),
          ),
          GreyOption(
            name: 'att_tcon',
            child: _attachTile(
              context,
              slot: 5,
              icon: Icons.person_outline_rounded,
              label: l.attachContact,
            ),
          ),
          InkWell(
            key: const ValueKey('attach-poll'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).pop('poll'),
            child: _attachTile(
              context,
              slot: 6,
              icon: Icons.bar_chart_rounded,
              label: l.attachPoll,
            ),
          ),
        ],
      ),
    );
  }
}

Widget _attachTile(
  BuildContext context, {
  required int slot,
  required IconData icon,
  required String label,
}) {
  final color = groupColor(context, slot);
  return SizedBox(
    width: 52,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.22),
          ),
          child: Icon(icon, size: 22, color: color),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

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
  // Ticked photos, in tick order (a chat photo only; a picture is one tap).
  final _picked = <GalleryPhoto>[];

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
      showSisNotice(
        context,
        AppLocalizations.of(context).attachLoadMoreFailed,
        isError: true,
      );
    }
  }

  /// A tap on a tile. A picture (square) is chosen at once and cropped; a
  /// chat photo is ticked or unticked.
  Future<void> _choose(GalleryPhoto p) async {
    if (!widget.square) {
      final at = _picked.indexWhere((e) => e.id == p.id);
      if (at >= 0) {
        setState(() => _picked.removeAt(at));
      } else if (_picked.length >= ExternalPicker.maxAttachments) {
        showSisNotice(
          context,
          AppLocalizations.of(context)
              .attachLimit(ExternalPicker.maxAttachments),
        );
      } else {
        setState(() => _picked.add(p));
      }
      return;
    }
    if (_opening) return;
    setState(() => _opening = true);
    PickedImage? image;
    try {
      image = await ref.read(galleryProvider).loadForCrop(p);
    } catch (_) {
      image = null; // a thrown load is a failed load, never a stuck sheet
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (image == null) {
      showSisNotice(
        context,
        AppLocalizations.of(context).photoOpenFailed,
        isError: true,
      );
      return;
    }
    await _finish([image], 0);
  }

  /// Loads every ticked photo and hands them back, in tick order.
  Future<void> _sendPicked() async {
    if (_opening) return;
    setState(() => _opening = true);
    final loaded = <PickedImage>[];
    for (final p in _picked) {
      try {
        final image = await ref.read(galleryProvider).load(p);
        if (image != null) loaded.add(image);
      } catch (_) {
        // a thrown load is a failed load; the others still go
      }
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (loaded.isEmpty) {
      showSisNotice(
        context,
        AppLocalizations.of(context).attachOpenFailedMany,
        isError: true,
      );
      return;
    }
    if (loaded.length < _picked.length) {
      showSisNotice(
        context,
        AppLocalizations.of(context).attachOpenFailedSome,
        isError: true,
      );
    }
    await _finish(loaded, 0);
  }

  /// The camera tile: one photo, straight to the caller.
  Future<void> _takePhoto() async {
    if (_opening) return;
    setState(() => _opening = true);
    final result = await ref.read(externalPickerProvider).takePhoto();
    if (!mounted) return;
    setState(() => _opening = false);
    switch (result) {
      case ExternalPickedImages(:final images) when images.isNotEmpty:
        await _finish(images, 0);
      case ExternalPickCancelled():
        return;
      case ExternalPickedImages() || ExternalPickFailed():
        showSisNotice(
          context,
          AppLocalizations.of(context).cameraFailed,
          isError: true,
        );
    }
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
        showSisNotice(
          context,
          AppLocalizations.of(context).attachOpenFailed,
          isError: true,
        );
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
              AppLocalizations.of(context).attachRecentPhotos,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (limited)
            TextButton(
              key: const ValueKey('sheet-allow-more'),
              onPressed: _selectMore,
              child: Text(AppLocalizations.of(context).attachAllowMore),
            ),
          TextButton.icon(
            key: const ValueKey('sheet-from-app'),
            onPressed: _fromApp,
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: Text(AppLocalizations.of(context).commonGallery),
          ),
        ],
      ),
    );

    final Widget body = _photos.isEmpty
        ? Center(child: Text(AppLocalizations.of(context).attachNoPhotos))
        : GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: _photos.length + (widget.square ? 0 : 1),
            itemBuilder: (context, i) {
              if (!widget.square && i == 0) {
                return _CameraTile(onTap: _opening ? null : _takePhoto);
              }
              final p = _photos[i - (widget.square ? 0 : 1)];
              return _Thumb(
                key: ValueKey('sheet-photo-${p.id}'),
                photo: p,
                onTap: () => _choose(p),
                showTick: !widget.square,
                selected: _picked.any((e) => e.id == p.id),
              );
            },
          );

    return SizedBox(
      height: height,
      child: Column(
        children: [
          header,
          Expanded(child: body),
          if (_picked.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('sheet-send'),
                  onPressed: _opening ? null : _sendPicked,
                  child: Text(
                    AppLocalizations.of(context)
                        .attachSendPhotos(_picked.length),
                  ),
                ),
              ),
            ),
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
                    AppLocalizations.of(context).attachFasterTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context).attachFasterBody,
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
                        permanentlyDenied
                            ? AppLocalizations.of(context).attachOpenSettings
                            : AppLocalizations.of(context).attachAllowPhotos,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('sheet-from-app'),
                    onPressed: onFromApp,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: Text(AppLocalizations.of(context).commonGallery),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('sheet-not-now'),
                    onPressed: onNotNow,
                    child: Text(AppLocalizations.of(context).attachNotNow),
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

/// The grid's first cell: take a photo now.
class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const ValueKey('sheet-camera'),
      onTap: onTap,
      child: ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_camera_rounded, size: 32, color: scheme.onSurface),
            const SizedBox(height: 4),
            Text(
              AppLocalizations.of(context).attachCamera,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends ConsumerStatefulWidget {
  const _Thumb({
    super.key,
    required this.photo,
    required this.onTap,
    this.showTick = false,
    this.selected = false,
  });

  final GalleryPhoto photo;
  final VoidCallback onTap;

  /// Draws the tick circle in the corner (a chat photo, not a picture).
  final bool showTick;
  final bool selected;

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
    final brand = SisBrand.of(context).brand;
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) => InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            switch (snapshot.data) {
              final Uint8List data => Image.memory(
                data,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
              // Not read yet, or unreadable: a quiet tile, but still tappable
              // (a limited-access photo can be slow, and a tap must never be
              // lost).
              null => ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
              ),
            },
            if (widget.selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: brand, width: 3),
                ),
              ),
            if (widget.showTick)
              Positioned(
                top: 6,
                right: 6,
                child: Icon(
                  widget.selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  key: ValueKey('sheet-tick-${widget.photo.id}'),
                  size: 24,
                  color: widget.selected ? brand : Colors.white,
                  shadows: const [Shadow(blurRadius: 3)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

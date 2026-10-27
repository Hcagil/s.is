import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/fade_scale_route.dart';
import '../../../app/notice.dart';
import '../../../app/swipe_back.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/gallery.dart';
import '../domain/message.dart';
import 'free_crop_screen.dart';
import 'photo_ticks.dart';

/// Opens the big photo view over [from] (the tapped tile's rect).
/// Returns the photos to send and the caption when the member taps Send,
/// or null when they go back.
/// [picked] is shared with the grid: ticks made here show there.
Future<({List<PickedImage> images, String caption})?> showAttachmentPreview(
  BuildContext context, {
  required List<GalleryPhoto> photos,
  required PhotoTicks picked,
  required int initial,
  String caption = '',
  Rect? from,
}) => Navigator.of(context).push<({List<PickedImage> images, String caption})>(
  fadeScaleRoute(
    from: from,
    settings: noSwipeBack,
    builder: (_) => AttachmentPreviewPage(
      photos: photos,
      picked: picked,
      initial: initial,
      caption: caption,
    ),
  ),
);

/// The big photo view: swipe through the grid photos, tick, crop, caption, send.
class AttachmentPreviewPage extends ConsumerStatefulWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.photos,
    required this.picked,
    required this.initial,
    this.caption = '',
  });

  final List<GalleryPhoto> photos;
  final PhotoTicks picked;
  final int initial;
  final String caption;

  @override
  ConsumerState<AttachmentPreviewPage> createState() =>
      _AttachmentPreviewPageState();
}

/// Bytes that cannot be decoded as a picture show a quiet tile, never a throw.
Widget _undecodable(BuildContext context, Object error, StackTrace? stack) {
  final scheme = Theme.of(context).colorScheme;
  return ColoredBox(
    color: scheme.surfaceContainerHigh,
    child: Center(
      child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
    ),
  );
}

class _AttachmentPreviewPageState extends ConsumerState<AttachmentPreviewPage> {
  // The version to show and send by photo id (cropped once the member crops).
  final _loaded = <String, PickedImage>{};
  // As read from the gallery; opening the crop again starts from here.
  final _originals = <String, PickedImage>{};
  final _thumbs = <String, Future<Uint8List?>>{};
  late final _caption = TextEditingController(text: widget.caption);
  late final _pager = PageController(initialPage: widget.initial);
  late int _page = widget.initial;
  bool _sending = false;

  GalleryPhoto get _current => widget.photos[_page];

  @override
  void initState() {
    super.initState();
    _ensure(_current);
  }

  @override
  void dispose() {
    _pager.dispose();
    _caption.dispose();
    super.dispose();
  }

  Future<Uint8List?> _thumb(GalleryPhoto p) =>
      _thumbs.putIfAbsent(p.id, () => ref.read(galleryProvider).thumbnail(p));

  /// Reads the full photo once (the thumbnail shows meanwhile); null when it
  /// cannot be read.
  Future<PickedImage?> _ensure(GalleryPhoto p) async {
    final have = _loaded[p.id];
    if (have != null) return have;
    PickedImage? image;
    try {
      image = await ref.read(galleryProvider).load(p);
    } catch (_) {
      image = null;
    }
    if (image == null) return null;
    _originals[p.id] = image;
    if (!mounted) return image;
    setState(() => _loaded[p.id] = image!);
    return image;
  }

  Future<void> _crop() async {
    final p = _current;
    final image = await _ensure(p);
    if (!mounted) return;
    if (image == null) {
      showSisNotice(
        context,
        AppLocalizations.of(context).photoOpenFailed,
        isError: true,
      );
      return;
    }
    final cropped = await openFreeCropScreen(context, _originals[p.id]!);
    if (cropped == null || !mounted) return;
    setState(() => _loaded[p.id] = cropped);
    if (!widget.picked.value.any((e) => e.id == p.id)) {
      widget.picked.toggle(context, p);
    }
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final chosen = widget.picked.value.isEmpty
        ? [_current]
        : widget.picked.value;
    final images = <PickedImage>[];
    for (final p in chosen) {
      final image = await _ensure(p);
      if (image != null) images.add(image);
    }
    if (!mounted) return;
    if (images.isEmpty) {
      setState(() => _sending = false);
      showSisNotice(
        context,
        AppLocalizations.of(context).attachOpenFailedMany,
        isError: true,
      );
      return;
    }
    Navigator.of(context).pop((images: images, caption: _caption.text.trim()));
  }

  Widget _pagerView() {
    return PageView.builder(
      key: const ValueKey('preview-pager'),
      controller: _pager,
      itemCount: widget.photos.length,
      onPageChanged: (p) {
        setState(() => _page = p);
        _ensure(widget.photos[p]);
      },
      itemBuilder: (_, i) {
        final p = widget.photos[i];
        final full = _loaded[p.id];
        if (full != null) {
          return Image.memory(
            full.bytes,
            key: ValueKey('preview-photo-$i'),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: _undecodable,
          );
        }
        return FutureBuilder<Uint8List?>(
          future: _thumb(p),
          builder: (_, s) {
            final data = s.data;
            if (data == null) return const SizedBox.expand();
            return Image.memory(
              data,
              key: ValueKey('preview-photo-$i'),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: _undecodable,
            );
          },
        );
      },
    );
  }

  Widget _strip() {
    return ValueListenableBuilder<List<GalleryPhoto>>(
      valueListenable: widget.picked,
      builder: (context, picked, _) {
        if (picked.isEmpty) return const SizedBox.shrink();
        final brand = SisBrand.of(context).brand;
        return SizedBox(
          height: 64,
          child: ListView.separated(
            key: const ValueKey('preview-thumbs'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: picked.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final p = picked[i];
              return InkWell(
                key: ValueKey('preview-thumb-$i'),
                onTap: () => _pager.animateToPage(
                  widget.photos.indexWhere((e) => e.id == p.id),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                ),
                child: Container(
                  width: 56,
                  height: 56,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: p.id == _current.id ? brand : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: FutureBuilder<Uint8List?>(
                    future: _thumb(p),
                    builder: (_, s) {
                      final data = s.data;
                      if (data == null) {
                        return ColoredBox(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                        );
                      }
                      return Image.memory(
                        data,
                        fit: BoxFit.cover,
                        errorBuilder: _undecodable,
                      );
                    },
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _cropButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        button: true,
        label: AppLocalizations.of(context).cropButtonLabel,
        child: GestureDetector(
          key: const ValueKey('preview-crop'),
          behavior: HitTestBehavior.opaque,
          onTap: _crop,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.1),
            ),
            child: Icon(
              Icons.crop_rounded,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final t = SisBrand.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('preview-caption'),
                controller: _caption,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(maxMessageLength),
                ],
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context).pickerAddCaption,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: AppLocalizations.of(context).commonSend,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  InkWell(
                    key: const ValueKey('preview-send'),
                    customBorder: const CircleBorder(),
                    onTap: _sending ? null : _send,
                    child: Ink(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: t.gradient,
                      ),
                      child: const Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Positioned(
                    top: -4,
                    right: -4,
                    child: ValueListenableBuilder<List<GalleryPhoto>>(
                      valueListenable: widget.picked,
                      builder: (_, picked, _) {
                        if (picked.isEmpty) return const SizedBox.shrink();
                        return IgnorePointer(
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(picked.length),
                            tween: Tween(begin: 1.15, end: 1),
                            duration: const Duration(milliseconds: 150),
                            builder: (_, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: Container(
                              key: const ValueKey('preview-badge'),
                              width: 20,
                              height: 20,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                border: Border.all(
                                  color: t.brand.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                '${picked.length}',
                                style: TextStyle(
                                  color: t.brand,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  height: 1,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tick() {
    return ValueListenableBuilder<List<GalleryPhoto>>(
      valueListenable: widget.picked,
      builder: (context, picked, _) {
        final on = picked.any((e) => e.id == _current.id);
        final scheme = Theme.of(context).colorScheme;
        return Semantics(
          button: true,
          selected: on,
          label: on
              ? AppLocalizations.of(context).attachTickSelected
              : AppLocalizations.of(context).attachTickSelect,
          child: GestureDetector(
            key: const ValueKey('preview-tick'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.picked.toggle(context, _current),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: AnimatedScale(
                  scale: on ? 1 : 0.9,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    on
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    size: 24,
                    color: on ? SisBrand.of(context).brand : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('preview-page'),
      appBar: AppBar(
        leading: BackButton(
          key: const ValueKey('preview-back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '${_page + 1} / ${widget.photos.length}',
          key: const ValueKey('preview-count'),
        ),
        actions: [_tick(), const SizedBox(width: 8)],
      ),
      body: Column(
        children: [
          Expanded(child: _pagerView()),
          _strip(),
          _cropButton(),
          _bottomBar(),
        ],
      ),
    );
  }
}

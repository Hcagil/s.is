import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/gallery.dart';

/// Shows the attachment sheet; null when the member closes it or backs out
/// without choosing a photo.
Future<PickedImage?> showAttachmentSheet(BuildContext context) =>
    showModalBottomSheet<PickedImage>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const AttachmentSheet(),
    );

/// The phone's recent photos to send from. Asks for photo access the first
/// time it opens; when access is missing or partial, shows SIS's own screen
/// for it instead of the phone's photos.
class AttachmentSheet extends ConsumerStatefulWidget {
  const AttachmentSheet({super.key});

  @override
  ConsumerState<AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends ConsumerState<AttachmentSheet> {
  GalleryAccess? _access;
  List<GalleryPhoto> _photos = const [];
  bool _loading = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gallery = ref.read(galleryProvider);
    final access = await gallery.requestAccess();
    final photos =
        access == GalleryAccess.full || access == GalleryAccess.limited
        ? await gallery.recent()
        : const <GalleryPhoto>[];
    if (!mounted) return;
    setState(() {
      _access = access;
      _photos = photos;
      _loading = false;
    });
  }

  Future<void> _choose(GalleryPhoto p) async {
    if (_opening) return;
    setState(() => _opening = true);
    final image = await ref.read(galleryProvider).load(p);
    if (!mounted) return;
    setState(() => _opening = false);
    if (image == null) {
      showSisNotice(context, 'That photo could not be opened.', isError: true);
      return;
    }
    Navigator.of(context).pop(image);
  }

  Future<void> _selectMore() async {
    await ref.read(galleryProvider).selectMore();
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
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
          onNotNow: () => Navigator.of(context).pop(),
        ),
      );
    }

    final limited = _access == GalleryAccess.limited;
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text('Photos', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (limited)
            TextButton(
              key: const ValueKey('sheet-allow-more'),
              onPressed: _selectMore,
              child: const Text('Allow more'),
            ),
        ],
      ),
    );

    final Widget body = _photos.isEmpty
        ? const Center(child: Text('No photos yet'))
        : GridView.builder(
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
  });

  final bool permanentlyDenied;
  final VoidCallback onAllow;
  final VoidCallback onOpenSettings;
  final VoidCallback onNotNow;

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
      builder: (context, snapshot) => switch (snapshot.data) {
        final Uint8List data => InkWell(
          onTap: widget.onTap,
          child: Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        // Not read yet, or unreadable: a quiet tile, not a tap target.
        null => ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
      },
    );
  }
}

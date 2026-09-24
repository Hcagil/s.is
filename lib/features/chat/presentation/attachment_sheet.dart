import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/gallery.dart';

/// What the member chose in the attachment sheet.
sealed class AttachmentChoice {
  const AttachmentChoice();
}

/// A photo from the sheet's own grid, ready to send.
final class ChosenPhoto extends AttachmentChoice {
  const ChosenPhoto(this.image);
  final PickedImage image;
}

/// Open the system photo picker instead.
final class UseSystemPicker extends AttachmentChoice {
  const UseSystemPicker();
}

/// Shows the attachment sheet; null when the member closes it.
Future<AttachmentChoice?> showAttachmentSheet(BuildContext context) =>
    showModalBottomSheet<AttachmentChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const AttachmentSheet(),
    );

/// The phone's recent photos to send from, with a way out to the system
/// picker. Asks for photo access the first time it opens.
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
    final photos = access == GalleryAccess.denied
        ? const <GalleryPhoto>[]
        : await gallery.recent();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That photo could not be opened.')),
      );
      return;
    }
    Navigator.of(context).pop(ChosenPhoto(image));
  }

  Future<void> _selectMore() async {
    await ref.read(galleryProvider).selectMore();
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text('Photos', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('sheet-system-picker'),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('All photos'),
            onPressed: () => Navigator.of(context).pop(const UseSystemPicker()),
          ),
        ],
      ),
    );

    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_access == GalleryAccess.denied) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Allow SIS to show your photos here, or pick one from all '
                'photos.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('sheet-allow'),
                onPressed: () {
                  setState(() => _loading = true);
                  _load();
                },
                child: const Text('Allow access'),
              ),
            ],
          ),
        ),
      );
    } else if (_photos.isEmpty && _access == GalleryAccess.full) {
      body = const Center(child: Text('No photos yet'));
    } else {
      final limited = _access == GalleryAccess.limited;
      body = GridView.builder(
        padding: const EdgeInsets.all(2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: _photos.length + (limited ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == _photos.length) return _SelectMoreTile(onTap: _selectMore);
          final p = _photos[i];
          return _Thumb(
            key: ValueKey('sheet-photo-${p.id}'),
            photo: p,
            onTap: () => _choose(p),
          );
        },
      );
    }

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        children: [
          header,
          Expanded(child: body),
        ],
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

class _SelectMoreTile extends StatelessWidget {
  const _SelectMoreTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('sheet-select-more'),
      onTap: onTap,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_photo_alternate_outlined),
              SizedBox(height: 4),
              Text('Select more'),
            ],
          ),
        ),
      ),
    );
  }
}

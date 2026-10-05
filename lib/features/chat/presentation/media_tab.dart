part of 'profile_pages.dart';

/// A photo grid, newest first; a tap opens the viewer at that photo.
class _MediaTab extends ConsumerWidget {
  const _MediaTab(this.conversationId);

  /// Null when there is no conversation to show photos from.
  final String? conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const empty = 'No photos shared yet';
    final id = conversationId;
    if (id == null) return const _Empty(empty);
    return _Async(
      ref.watch(sharedMediaProvider(id)),
      empty: empty,
      builder: (photos) {
        final paths = [for (final m in photos) m.attachmentPath!];
        return GridView.builder(
          key: const ValueKey('media-grid'),
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: paths.length,
          itemBuilder: (context, i) => GestureDetector(
            key: ValueKey('media-${paths[i]}'),
            onTap: () => openPhotoViewer(context, paths, i),
            child: _Thumb(paths[i]),
          ),
        );
      },
    );
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb(this.path);

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
    );
    return switch (ref.watch(attachmentBytesProvider(path))) {
      // Decoded at thumbnail size: a grid of full photos would hold every one
      // at full resolution in memory.
      AsyncData(:final value) => Image.memory(
        value,
        cacheWidth: 300,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
      _ => placeholder,
    };
  }
}

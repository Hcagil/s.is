part of 'message_screen.dart';

/// A tile in an album grid.
///
/// Shows a photo, blurred if gated or waiting, with overlays for pending,
/// and the number of additional photos in the album if this is the last tile.
class _AlbumTile extends ConsumerWidget {
  const _AlbumTile(this.message, {this.more = 0});

  final Message message;
  final int more;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = message.attachmentPath;
    final gate = path == null || message.localImage != null
        ? null
        : ref.watch(photoGateProvider(path));
    // false: auto-download says no and the member has not tapped yet. While
    // the phone's copy is still being looked for nothing downloads either.
    final gated = gate?.value == false;
    final waiting = gate != null && !gate.hasValue && !gate.hasError;

    Widget child;
    if (message.localImage != null) {
      child = Image.memory(
        message.localImage!,
        cacheWidth: 560,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else if (path == null) {
      child = const SizedBox.shrink();
    } else if (gated || waiting) {
      final preview = message.attachmentPreview;
      final blurred = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: preview == null
            ? Container(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
              )
            : Image.memory(
                preview,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
      );
      child = Stack(
        fit: StackFit.expand,
        children: [
          blurred,
          if (gated)
            Center(
              child: Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_downward_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
        ],
      );
    } else {
      final bytes = ref.watch(attachmentBytesProvider(path));
      child = switch (bytes) {
        AsyncData(:final value) => Image.memory(
          value,
          cacheWidth: 560,
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) => Container(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
        AsyncError() => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: const Icon(Icons.broken_image_outlined),
        ),
        _ => ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: message.attachmentPreview == null
              ? Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                )
              : Image.memory(
                  message.attachmentPreview!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
        ),
      };
    }

    final pending = message.isPending;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (pending) const ColoredBox(color: Color(0x59000000)),
        if (pending)
          const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: SisProgressRing(color: Colors.white),
            ),
          ),
        if (more > 0) const ColoredBox(color: Color(0x73000000)),
        if (more > 0)
          Center(
            child: Text(
              '+$more',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

/// A grid of photos in an album: the first four, the fourth carrying "+N" for the photos not shown.
class _AlbumGrid extends ConsumerWidget {
  const _AlbumGrid(this.album, {required this.radius, this.time});

  /// Two or more photos, oldest first.
  final List<Message> album;
  final double radius;

  /// Time and tick drawn on a soft gradient at the bottom right; null when a caption carries them.
  final Widget? time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rects = albumRects(album.length);
    final shown = albumTiles(album.length);
    final whole = Rect.fromLTWH(
      0,
      0,
      albumWidth,
      rects.map((r) => r.bottom).reduce(math.max),
    );
    final hidden = album.length > 4 ? album.length - 4 : 0;
    final paths = [
      for (final m in album)
        if (m.attachmentPath != null) m.attachmentPath!,
    ];

    return SizedBox(
      key: ValueKey('album-${album.first.id}'),
      width: albumWidth,
      height: whole.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            for (var i = 0; i < shown; i++)
              Positioned.fromRect(
                rect: rects[i],
                child: GestureDetector(
                  onTap: album[i].attachmentPath == null
                      ? null
                      : () => _Attachment(album[i])._view(
                          context,
                          ref,
                          album[i].attachmentPath!,
                          within: paths,
                        ),
                  child: ClipRRect(
                    borderRadius: albumCorners(rects[i], whole, radius, 4),
                    child: _AlbumTile(album[i], more: i == 3 ? hidden : 0),
                  ),
                ),
              ),
            if (time != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 56,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.45),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (time != null) Positioned(right: 8, bottom: 6, child: time!),
          ],
        ),
      ),
    );
  }
}

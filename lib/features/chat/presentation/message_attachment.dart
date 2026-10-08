part of 'message_screen.dart';

/// An attachment, fetched through a signed URL issued only to a member.
///
/// The URL is short-lived, so it is resolved when the bubble is built rather
/// than stored with the message.
class _Attachment extends ConsumerWidget {
  const _Attachment(this.message, {this.radius = 6});

  final Message message;

  /// Corner radius of the picture; a photo with no bubble around it uses the
  /// bubble radius.
  final double radius;

  /// The open conversation's photos, oldest first, and this one's place.
  void _view(BuildContext context, WidgetRef ref, String path) {
    final paths = [
      for (final m in ref.read(messagesProvider).value ?? const <Message>[])
        if (m.attachmentPath != null) m.attachmentPath!,
    ];
    final index = paths.indexOf(path);
    if (index < 0) return;
    openPhotoViewer(
      context,
      paths,
      index,
      onMenu: (viewerContext, viewerRef, shown) {
        final message =
            (viewerRef.read(messagesProvider).value ?? const <Message>[])
                .where((m) => m.attachmentPath == shown)
                .firstOrNull;
        return message == null
            ? Future.value(false)
            : showMessageMenu(
                viewerContext,
                viewerRef,
                message,
                photoViewer: true,
              );
      },
    );
  }

  /// The most a photo takes in a bubble.
  static const _bounds = BoxConstraints(maxHeight: 260, maxWidth: 280);

  /// The box the photo will take once decoded, known from its preview (a
  /// tiny PNG of the same shape) before any bytes arrive: the placeholder,
  /// the blurred preview and the photo all take exactly this box, so the
  /// bubble never changes height. Null without a preview.
  ///
  /// This is what keeps scrolling honest: the list is reversed, and a
  /// bubble that grows between the viewport and the newest message shoves
  /// the rows on screen away from it -- scrolling down toward the newest
  /// message then fights every photo that loads on the way (0.30.16).
  static Size? _photoBox(Uint8List? preview) {
    final size = pngDimensions(preview);
    if (size == null) return null;
    // Scaled up as well as down: the preview is only 24 px wide.
    final scale = math.min(
      _bounds.maxWidth / size.width,
      _bounds.maxHeight / size.height,
    );
    return Size(size.width * scale, size.height * scale);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = message.attachmentPath;
    final box = _photoBox(message.attachmentPreview);
    Widget sized(Widget child) => box == null
        ? child
        : SizedBox(width: box.width, height: box.height, child: child);
    final gate = path == null || message.localImage != null
        ? null
        : ref.watch(photoGateProvider(path));
    // false: auto-download says no and the member has not tapped yet. While
    // the phone's copy is still being looked for nothing downloads either.
    final gated = gate?.value == false;
    final waiting = gate != null && !gate.hasValue && !gate.hasError;
    return GestureDetector(
      key: ValueKey('attachment-${path ?? message.id}'),
      onTap: path == null
          ? null
          : gated
          ? () => ref.read(photoApprovalsProvider.notifier).approve(path)
          : () => _view(context, ref, path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ConstrainedBox(
          constraints: _bounds,
          child: switch ((message.localImage, path)) {
            // Your own photo, straight from the phone: shown from the tap on,
            // never swapped for the downloaded copy (the swap flashed blank).
            // The logo spins only while it uploads.
            (final Uint8List local, _) => Stack(
              alignment: Alignment.center,
              children: [
                Image.memory(
                  local,
                  key: const ValueKey('attachment-local'),
                  cacheWidth: 560,
                  fit: BoxFit.cover,
                ),
                if (path == null) const SisLoadingLogo(size: 40),
              ],
            ),
            (_, final String _) when gated || waiting => Semantics(
              button: gated,
              label: gated
                  ? AppLocalizations.of(context).filePhotoTapToDownload
                  : null,
              child: Stack(
                key: ValueKey('attachment-download-${message.id}'),
                alignment: Alignment.center,
                children: [_previewBox(box), if (gated) _ring(spinning: false)],
              ),
            ),
            (_, final String path) => switch (ref.watch(
              attachmentBytesProvider(path),
            )) {
              AsyncData(:final value) => sized(
                Image.memory(
                  value,
                  key: const ValueKey('attachment-image'),
                  cacheWidth: 560,
                  fit: BoxFit.cover,
                  errorBuilder: (context, _, _) => _failed(
                    context,
                    AppLocalizations.of(context).commonImageUnavailable,
                  ),
                ),
              ),
              AsyncError(:final error) => sized(
                _failed(
                  context,
                  error is Failure
                      ? error.message
                      : AppLocalizations.of(context).commonImageUnavailable,
                ),
              ),
              // The preview that came with the message, blurred, until the
              // photo is here. Its box is the photo's own (see _photoBox);
              // a preview that is not a PNG keeps the old fixed size.
              _ => _withRing(
                _previewBox(box),
                spinning: ref.watch(photoApprovalsProvider).contains(path),
              ),
            },
            _ => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }

  Widget _previewBox(Size? box) {
    return switch (message.attachmentPreview) {
      final Uint8List preview => SizedBox(
        height: box?.height ?? 180,
        width: box?.width ?? 240,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Image.memory(
            preview,
            key: const ValueKey('attachment-preview'),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // Valid base64 can still be a broken image: then just
            // wait for the photo.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
      null => const SizedBox(
        height: 120,
        width: 180,
        child: Center(child: SisLoadingLogo(size: 40)),
      ),
    };
  }

  Widget _withRing(Widget child, {required bool spinning}) {
    return spinning
        ? Stack(
            alignment: Alignment.center,
            children: [child, _ring(spinning: true)],
          )
        : child;
  }

  Widget _ring({required bool spinning}) {
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0x73000000),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: CircularProgressIndicator(
                value: spinning ? null : 0.75,
                strokeWidth: 3,
                color: Colors.white,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
          const Icon(
            Icons.arrow_downward_rounded,
            size: 20,
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _failed(BuildContext context, String reason) => Container(
    height: 96,
    width: 180,
    alignment: Alignment.center,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(reason, textAlign: TextAlign.center),
    ),
  );
}

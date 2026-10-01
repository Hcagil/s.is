import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../application/chat_controllers.dart';
import 'conversation_list.dart';

/// Opens [paths] full-screen at [index]: swipe between them, pinch to zoom.
Future<void> openPhotoViewer(
  BuildContext context,
  List<String> paths,
  int index, {
  bool isAvatar = false,
}) => Navigator.of(context).push(
  // Not opaque: the chat shows through while a swipe-down fades the black.
  PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) =>
        PhotoViewer(paths: paths, initialIndex: index, isAvatar: isAvatar),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

/// Full-screen photos, dark whatever the theme: photos read best on black.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.paths,
    this.initialIndex = 0,
    this.isAvatar = false,
  });

  /// Attachment storage paths, in the order the caller shows them -- or, when
  /// [isAvatar], avatar storage paths (there is only ever one).
  final List<String> paths;
  final int initialIndex;

  /// True when [paths] are avatar-bucket pictures (profile or group), read
  /// through [avatarBytesProvider] instead of [attachmentBytesProvider].
  final bool isAvatar;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer>
    with SingleTickerProviderStateMixin {
  /// A drag that ends past this many logical pixels, or a fling faster than
  /// [_closeVelocity], closes the viewer; anything shorter springs back.
  static const _closeDistance = 120.0;
  static const _closeVelocity = 700.0;

  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late final _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  double _dy = 0;

  /// The shown photo is pinch-zoomed: a drag then pans it instead of closing.
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    _back.dispose();
    super.dispose();
  }

  void _release(DragEndDetails d) {
    if (_dy > _closeDistance ||
        d.velocity.pixelsPerSecond.dy > _closeVelocity) {
      Navigator.of(context).pop();
      return;
    }
    final from = _dy;
    void step() => setState(
      () => _dy = from * (1 - Curves.easeOut.transform(_back.value)),
    );
    _back
      ..reset()
      ..addListener(step);
    _back.forward().whenComplete(() => _back.removeListener(step));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(
        alpha: (1 - _dy / 400).clamp(0.0, 1.0),
      ),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          '${_index + 1} of ${widget.paths.length}',
          key: const ValueKey('viewer-position'),
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: Transform.translate(
        offset: Offset(0, _dy),
        child: GestureDetector(
          // Null while zoomed: no drag recogniser, so the photo pans.
          onVerticalDragStart: _zoomed ? null : (_) => _back.stop(),
          onVerticalDragUpdate: _zoomed
              ? null
              : (d) => setState(() => _dy = math.max(0, _dy + d.delta.dy)),
          onVerticalDragEnd: _zoomed ? null : _release,
          child: PageView.builder(
            key: const ValueKey('viewer-pages'),
            controller: _pages,
            itemCount: widget.paths.length,
            onPageChanged: (i) => setState(() {
              _index = i;
              _zoomed = false;
            }),
            itemBuilder: (context, i) => _Photo(
              widget.paths[i],
              isAvatar: widget.isAvatar,
              onZoomed: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Photo extends ConsumerStatefulWidget {
  const _Photo(this.path, {required this.isAvatar, required this.onZoomed});

  final String path;
  final bool isAvatar;
  final ValueChanged<bool> onZoomed;

  @override
  ConsumerState<_Photo> createState() => _PhotoState();
}

class _PhotoState extends ConsumerState<_Photo> {
  final _zoom = TransformationController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const white = TextStyle(color: Colors.white70);
    final path = widget.path;
    final bytesValue = widget.isAvatar
        ? ref.watch(avatarBytesProvider(path))
        : ref.watch(attachmentBytesProvider(path));
    return switch (bytesValue) {
      AsyncData(:final value) => InteractiveViewer(
        transformationController: _zoom,
        onInteractionEnd: (_) =>
            widget.onZoomed(_zoom.value.getMaxScaleOnAxis() > 1.01),
        maxScale: 5,
        child: Center(
          child: Image.memory(
            value,
            key: ValueKey('viewer-image-$path'),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Text('Image unavailable', style: white),
          ),
        ),
      ),
      AsyncError(:final error) => Center(
        child: Text(reasonOf(error), style: white),
      ),
      _ => const Center(child: SisLoadingLogo(size: 48)),
    };
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/route_stack.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';

/// Opens [paths] full-screen at [index]: swipe between them, pinch to zoom.
Future<void> openPhotoViewer(
  BuildContext context,
  List<String> paths,
  int index, {
  bool isAvatar = false,
  PhotoMenu? onMenu,
}) => Navigator.of(context).push(
  // Not opaque: the chat shows through while a swipe-down fades the black.
  PageRouteBuilder<void>(
    settings: fullScreenMedia,
    opaque: false,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => PhotoViewer(
      paths: paths,
      initialIndex: index,
      isAvatar: isAvatar,
      onMenu: onMenu,
    ),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

/// Opens the message menu for the photo at [path]; true when the viewer
/// should close (reply started, or the photo was deleted). The [ref] is the
/// viewer's own, so it outlives whichever bubble opened the viewer.
typedef PhotoMenu = Future<bool> Function(
  BuildContext context,
  WidgetRef ref,
  String path,
);

/// Full-screen photos, dark whatever the theme: photos read best on black.
class PhotoViewer extends ConsumerStatefulWidget {
  const PhotoViewer({
    super.key,
    required this.paths,
    this.initialIndex = 0,
    this.isAvatar = false,
    this.onMenu,
  });

  /// Attachment storage paths, in the order the caller shows them -- or, when
  /// [isAvatar], avatar storage paths (there is only ever one).
  final List<String> paths;
  final int initialIndex;

  /// True when [paths] are avatar-bucket pictures (profile or group), read
  /// through [avatarBytesProvider] instead of [attachmentBytesProvider].
  final bool isAvatar;

  /// When set, the app bar shows a menu button for the shown photo.
  final PhotoMenu? onMenu;

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer>
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

  int _pointers = 0;
  bool _pinching = false;

  /// Zoomed or mid-pinch: no page swipe and no swipe-down may win the gesture.
  bool get _locked => _zoomed || _pinching;

  void _pointer(int delta) {
    _pointers = math.max(0, _pointers + delta);
    final pinching = _pointers >= 2;
    if (pinching != _pinching) setState(() => _pinching = pinching);
  }

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
          AppLocalizations.of(context)
              .viewerCounter(_index + 1, widget.paths.length),
          key: const ValueKey('viewer-position'),
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        actions: [
          if (widget.onMenu != null)
            IconButton(
              key: const ValueKey('viewer-menu'),
              icon: const Icon(Icons.more_horiz),
              tooltip: AppLocalizations.of(context).viewerMore,
              onPressed: () async {
                final nav = Navigator.of(context);
                final close = await widget.onMenu!(
                  context,
                  ref,
                  widget.paths[_index],
                );
                if (close && mounted) nav.pop();
              },
            ),
        ],
      ),
      body: Transform.translate(
        offset: Offset(0, _dy),
        child: Listener(
          onPointerDown: (_) => _pointer(1),
          onPointerUp: (_) => _pointer(-1),
          onPointerCancel: (_) => _pointer(-1),
          child: GestureDetector(
            // Null while zoomed: no drag recogniser, so the photo pans.
            onVerticalDragStart: _locked ? null : (_) => _back.stop(),
            onVerticalDragUpdate: _locked
                ? null
                : (d) => setState(() => _dy = math.max(0, _dy + d.delta.dy)),
            onVerticalDragEnd: _locked ? null : _release,
            child: PageView.builder(
              key: const ValueKey('viewer-pages'),
              controller: _pages,
              physics: _locked ? const NeverScrollableScrollPhysics() : null,
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

class _PhotoState extends ConsumerState<_Photo>
    with SingleTickerProviderStateMixin {
  static const _doubleTapScale = 2.5;

  final _zoom = TransformationController();
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Offset _tap = Offset.zero;
  int _down = 0;

  void _report() => widget.onZoomed(_zoom.value.getMaxScaleOnAxis() > 1.01);

  /// Zoomed: back to fit. At fit: zoom in about the tapped spot.
  void _toggleZoom() {
    final zoomedIn = _zoom.value.getMaxScaleOnAxis() > 1.01;
    final k = 1 - _doubleTapScale;
    final target = Matrix4.identity();
    if (!zoomedIn) {
      target
        ..translateByDouble(_tap.dx * k, _tap.dy * k, 0, 1)
        ..scaleByDouble(_doubleTapScale, _doubleTapScale, 1, 1);
    }
    final tween = Matrix4Tween(
      begin: _zoom.value,
      end: target,
    ).chain(CurveTween(curve: Curves.easeOut));
    void step() {
      _zoom.value = tween.evaluate(_anim);
      _report();
    }

    _anim
      ..reset()
      ..addListener(step);
    _anim.forward().whenComplete(() => _anim.removeListener(step));
  }

  @override
  void dispose() {
    _anim.dispose();
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
      AsyncData(:final value) => Listener(
        onPointerDown: (_) {
          if (++_down >= 2) _anim.stop();
        },
        onPointerUp: (_) => _down = math.max(0, _down - 1),
        onPointerCancel: (_) => _down = math.max(0, _down - 1),
        child: GestureDetector(
          onDoubleTapDown: (d) => _tap = d.localPosition,
          onDoubleTap: _toggleZoom,
          child: InteractiveViewer(
            transformationController: _zoom,
            onInteractionStart: (_) => _anim.stop(),
            onInteractionUpdate: (_) => _report(),
            onInteractionEnd: (_) => _report(),
            maxScale: 5,
            child: Center(
              child: Image.memory(
                value,
                key: ValueKey('viewer-image-$path'),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Text(
                  AppLocalizations.of(context).commonImageUnavailable,
                  style: white,
                ),
              ),
            ),
          ),
        ),
      ),
      AsyncError(:final error) => Center(
        child: Text(failureReason(error), style: white),
      ),
      _ => const Center(child: SisLoadingLogo(size: 48)),
    };
  }
}

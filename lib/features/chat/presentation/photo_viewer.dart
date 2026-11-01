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
  static const _flingVelocity = 300.0;

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

  /// A zoomed photo handed its extra sideways drag to the pages; true until
  /// the pages have settled. Holds [_index] fixed meanwhile.
  bool _handOver = false;

  double get _viewport => _pages.position.viewportDimension;

  /// Pixels the pages are dragged away from the shown photo (negative: the
  /// previous photo is coming in).
  double get _offset =>
      _handOver ? _pages.position.pixels - _index * _viewport : 0;

  void _setOffset(double o) {
    final w = _viewport;
    final lo = _index > 0 ? -w : 0.0;
    final hi = _index < widget.paths.length - 1 ? w : 0.0;
    final c = o.clamp(lo, hi);
    _handOver = c != 0; // back at 0 (or no neighbour): nothing to settle
    _pages.position.jumpTo(_index * w + c);
  }

  /// Finger lifted: past half or a fast fling moves a page, else spring back.
  Future<void> _settle(double vx) async {
    final off = _offset;
    final fling = vx.abs() > _flingVelocity && vx.sign == -off.sign;
    final dir = (fling || off.abs() > _viewport / 2) ? off.sign.toInt() : 0;
    final to = (_index + dir).clamp(0, widget.paths.length - 1);
    await _pages.animateToPage(
      to,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    setState(() {
      _handOver = false;
      if (to != _index) {
        _index = to;
        _zoomed = false;
      }
    });
  }

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
              onPageChanged: (i) {
                if (_handOver) return;
                setState(() {
                  _index = i;
                  _zoomed = false;
                });
              },
              itemBuilder: (context, i) => _Photo(
                widget.paths[i],
                isAvatar: widget.isAvatar,
                current: i == _index,
                pageOffset: () => _offset,
                onOffset: _setOffset,
                onRelease: _settle,
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
  const _Photo(
    this.path, {
    required this.isAvatar,
    required this.onZoomed,
    required this.current,
    required this.pageOffset,
    required this.onOffset,
    required this.onRelease,
  });

  final String path;
  final bool isAvatar;
  final ValueChanged<bool> onZoomed;
  final bool current;
  final ValueGetter<double> pageOffset;
  final ValueChanged<double> onOffset;
  final ValueChanged<double> onRelease;

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
  Matrix4 _last = Matrix4.identity();

  bool get _isZoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  /// Zoomed photo at its sideways edge: the drag left over moves the pages.
  void _handOver(ScaleUpdateDetails d) {
    if (d.pointerCount != 1 || !_isZoomed) return;
    final off = widget.pageOffset();
    final dx = d.focalPointDelta.dx;
    if (off != 0) {
      _zoom.value = _last.clone(); // the finger belongs to the pages now
      final next = off - dx;
      widget.onOffset(
        (off < 0 && next > 0) || (off > 0 && next < 0) ? 0 : next,
      );
      return;
    }
    final extra = dx - (_zoom.value.storage[12] - _last.storage[12]);
    if (extra.abs() > 0.5) widget.onOffset(-extra);
  }

  void _report() => widget.onZoomed(_isZoomed);

  /// Zoomed: back to fit. At fit: zoom in about the tapped spot.
  void _toggleZoom() {
    final zoomedIn = _isZoomed;
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
  void didUpdateWidget(_Photo old) {
    super.didUpdateWidget(old);
    // The photo we left goes back to fit (after the frame: the viewer listens).
    if (old.current && !widget.current) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _zoom.value = Matrix4.identity();
      });
    }
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
            onInteractionStart: (_) {
              _anim.stop();
              _last = _zoom.value.clone();
            },
            onInteractionUpdate: (d) {
              _report();
              _handOver(d);
              _last = _zoom.value.clone();
            },
            onInteractionEnd: (d) {
              _report();
              if (d.pointerCount == 0 && widget.pageOffset() != 0) {
                widget.onRelease(d.velocity.pixelsPerSecond.dx);
              }
            },
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

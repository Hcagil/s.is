import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/swipe_back.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';

/// Opens the crop screen over [source] (an upright, already-decoded photo,
/// as the gallery grid or "From an app" hand back): the photo under a
/// square frame, panned and pinch-zoomed with the fingers, the photo
/// always covering the square -- no empty edges. "Use" crops, scales and
/// re-encodes it on the phone and returns the result; the back button
/// returns null and changes nothing.
Future<PickedImage?> openCropScreen(BuildContext context, PickedImage source) =>
    Navigator.of(context).push<PickedImage?>(
      MaterialPageRoute(
        settings: noSwipeBack,
        builder: (_) => CropScreen(source: source),
      ),
    );

/// The square-crop screen: a photo under a square frame, moved and zoomed
/// with the fingers. Public so a test can pump it directly.
class CropScreen extends ConsumerStatefulWidget {
  const CropScreen({super.key, required this.source});

  /// The uncropped photo to frame.
  final PickedImage source;

  @override
  ConsumerState<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends ConsumerState<CropScreen> {
  /// The square frame's side, in logical pixels.
  static const _viewport = 320.0;
  static const _maxScale = 4.0;

  /// How far the dimming reaches past the frame on every side.
  static const _dimReach = 1200.0;

  final _transform = TransformationController();
  ui.Image? _image;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(widget.source.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      image = frame.image;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      image.dispose();
      return;
    }
    // First framing centred: start the cover-fit photo centred in the
    // square frame, at the minimum (cover) zoom -- the same framing the
    // old automatic centre crop produced.
    final cover = _coverSize(image.width.toDouble(), image.height.toDouble());
    _transform.value = Matrix4.translationValues(
      -(cover.width - _viewport) / 2,
      -(cover.height - _viewport) / 2,
      0,
    );
    setState(() => _image = image);
  }

  @override
  void dispose() {
    _image?.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// The size the photo is drawn at, at [InteractiveViewer] scale 1:
  /// `BoxFit.cover` into the [_viewport] square, so it always at least
  /// fills the square before any pinch-zoom -- never an empty edge.
  Size _coverSize(double w, double h) {
    final scale = w < h ? _viewport / w : _viewport / h;
    return Size(w * scale, h * scale);
  }

  /// Slider zoom: scales about the frame's centre, then keeps the frame
  /// inside the photo.
  void _zoomTo(double target, Size cover) {
    final m = _transform.value;
    final s = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    const c = _viewport / 2;
    final tx = (c - (c - t.x) / s * target)
        .clamp(_viewport - cover.width * target, 0.0)
        .toDouble();
    final ty = (c - (c - t.y) / s * target)
        .clamp(_viewport - cover.height * target, 0.0)
        .toDouble();
    _transform.value = Matrix4.diagonal3Values(target, target, 1)
      ..setTranslationRaw(tx, ty, 0);
  }

  Future<void> _use() async {
    final image = _image;
    if (image == null || _busy) return;
    setState(() => _busy = true);
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final cover = _coverSize(w, h);
    // cover.width / w == cover.height / h: the one uniform scale from the
    // original photo's pixels to the cover-fit size InteractiveViewer's own
    // scale multiplies from.
    final coverScale = cover.width / w;
    final matrix = _transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    // The visible viewport rect, back-projected onto the cover-fit photo,
    // then onto the original photo's own pixel fractions.
    final left = (-translation.x / scale) / coverScale / w;
    final top = (-translation.y / scale) / coverScale / h;
    final side = (_viewport / scale) / coverScale;
    final right = left + side / w;
    final bottom = top + side / h;
    final result = await ref
        .read(pictureCropperProvider)
        .crop(
          widget.source.bytes,
          left: left.clamp(0.0, 1.0),
          top: top.clamp(0.0, 1.0),
          right: right.clamp(0.0, 1.0),
          bottom: bottom.clamp(0.0, 1.0),
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) {
      showSisNotice(context, 'That photo could not be used.', isError: true);
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(AppLocalizations.of(context).cropTitle),
        actions: [
          TextButton(
            key: const ValueKey('crop-use'),
            onPressed: image == null || _busy ? null : _use,
            child: Text(
              AppLocalizations.of(context).cropChoose,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(height: 3, child: _busy ? const SisProgressLine() : null),
          Expanded(
            child: Center(
              child: _failed
                  ? const Text(
                      'That photo could not be opened.',
                      style: TextStyle(color: Colors.white70),
                    )
                  : image == null
                  ? const SisLoadingLogo(size: 48)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          key: const ValueKey('crop-frame'),
                          width: _viewport,
                          height: _viewport,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              InteractiveViewer(
                                key: const ValueKey('crop-viewer'),
                                transformationController: _transform,
                                constrained: false,
                                minScale: 1,
                                maxScale: _maxScale,
                                boundaryMargin: EdgeInsets.zero,
                                clipBehavior: Clip.none,
                                child: SizedBox(
                                  width: _coverSize(
                                    image.width.toDouble(),
                                    image.height.toDouble(),
                                  ).width,
                                  height: _coverSize(
                                    image.width.toDouble(),
                                    image.height.toDouble(),
                                  ).height,
                                  child: RawImage(
                                    image: image,
                                    fit: BoxFit.fill,
                                  ),
                                ),
                              ),
                              // Everything outside the frame is dimmed.
                              const Positioned(
                                left: -_dimReach,
                                top: -_dimReach,
                                right: -_dimReach,
                                bottom: -_dimReach,
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    key: ValueKey('crop-dim'),
                                    painter: _DimOutside(
                                      Rect.fromLTWH(
                                        _dimReach,
                                        _dimReach,
                                        _viewport,
                                        _viewport,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        ColoredBox(
                          color: Colors.black,
                          child: SizedBox(
                            width: double.infinity,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 20),
                                _CropPreview(
                                  image: image,
                                  transform: _transform,
                                  cover: _coverSize(
                                    image.width.toDouble(),
                                    image.height.toDouble(),
                                  ),
                                  viewport: _viewport,
                                ),
                                const SizedBox(height: 14),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 30,
                                  ),
                                  child: ListenableBuilder(
                                    listenable: _transform,
                                    builder: (_, _) => Slider(
                                      key: const ValueKey('crop-zoom'),
                                      min: 1,
                                      max: _maxScale,
                                      value: _transform.value
                                          .getMaxScaleOnAxis()
                                          .clamp(1.0, _maxScale)
                                          .toDouble(),
                                      onChanged: (v) => _zoomTo(
                                        v,
                                        _coverSize(
                                          image.width.toDouble(),
                                          image.height.toDouble(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  AppLocalizations.of(context).cropGestureHint,
                                  key: const ValueKey('crop-hint'),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A live circle of the frame, so the member sees how the round picture will
/// look while moving the photo.
class _CropPreview extends StatelessWidget {
  const _CropPreview({
    required this.image,
    required this.transform,
    required this.cover,
    required this.viewport,
  });

  final ui.Image image;
  final TransformationController transform;
  final Size cover;
  final double viewport;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipOval(
          key: const ValueKey('crop-preview'),
          child: SizedBox(
            width: 72,
            height: 72,
            child: FittedBox(
              child: SizedBox(
                width: viewport,
                height: viewport,
                child: ClipRect(
                  child: ListenableBuilder(
                    listenable: transform,
                    builder: (_, _) => Transform(
                      transform: transform.value,
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: 0,
                        minHeight: 0,
                        maxWidth: cover.width,
                        maxHeight: cover.height,
                        child: SizedBox(
                          width: cover.width,
                          height: cover.height,
                          child: RawImage(image: image, fit: BoxFit.fill),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.cropPreview,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(
              width: 200,
              child: Text(
                l.cropPreviewHint,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Dims everything except [hole], the crop frame.
class _DimOutside extends CustomPainter {
  const _DimOutside(this.hole);

  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(hole),
      Paint()..color = const Color(0x99000000),
    );
  }

  @override
  bool shouldRepaint(_DimOutside old) => old.hole != hole;
}

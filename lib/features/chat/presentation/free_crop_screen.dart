import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/swipe_back.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import 'crop_dock.dart';
import 'crop_frame.dart';
import 'crop_painters.dart';

/// Opens the free-aspect crop screen over [source]. Done returns the cropped picture, Cancel or back returns null.
Future<PickedImage?> openFreeCropScreen(
  BuildContext context,
  PickedImage source,
) => Navigator.of(context).push<PickedImage?>(
  MaterialPageRoute(
    settings: noSwipeBack,
    builder: (_) => FreeCropScreen(source: source),
  ),
);

/// The free-aspect crop screen: frame with handles, aspect list, rotate, reset.
class FreeCropScreen extends ConsumerStatefulWidget {
  /// Creates the screen over [source].
  const FreeCropScreen({super.key, required this.source});

  /// The uncropped photo.
  final PickedImage source;

  @override
  ConsumerState<FreeCropScreen> createState() => _FreeCropScreenState();
}

class _FreeCropScreenState extends ConsumerState<FreeCropScreen>
    with TickerProviderStateMixin {
  ui.Image? _image;
  bool _failed = false;
  bool _busy = false;
  int _turns = 0;
  Rect _frame = fullFrame;
  double? _ratio;
  FrameGrab _grab = FrameGrab.none;
  int _chip = 0;
  bool _grid = false;
  Rect _from = fullFrame;
  Size _prevTurned = Size.zero;
  bool _limitBuzzed = false;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1,
  );
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1,
  );
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..forward();

  /// The frame as drawn now: glides from [_from] to [_frame] in 250 ms.
  Rect get _shown => Rect.lerp(
    _from,
    _frame,
    const Cubic(0.2, 0, 0, 1).transform(_move.value),
  )!;

  void _glide(Rect to) {
    _from = _shown;
    _frame = to;
    _move.forward(from: 0);
  }

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
    setState(() => _image = image);
  }

  @override
  void dispose() {
    _spin.dispose();
    _move.dispose();
    _enter.dispose();
    _image?.dispose();
    super.dispose();
  }

  bool get _changed => _turns != 0 || _frame != fullFrame || _ratio != null;

  Size get _turned {
    if (_image == null) return Size.zero;
    return _turns.isOdd
        ? Size(_image!.height.toDouble(), _image!.width.toDouble())
        : Size(_image!.width.toDouble(), _image!.height.toDouble());
  }

  void _rotate() {
    HapticFeedback.selectionClick();
    setState(() {
      _prevTurned = _turned;
      _turns = (_turns + 1) % 4;
      _glide(rotateFrameCcw(_frame));
      final r = _ratio;
      if (r != null) _ratio = 1 / r;
      _spin.forward(from: 0);
    });
  }

  void _reset() {
    HapticFeedback.selectionClick();
    setState(() {
      _prevTurned = Size.zero;
      _turns = 0;
      _chip = 0;
      _ratio = null;
      _glide(fullFrame);
      _spin.value = 1;
    });
  }

  void _pickAspect(int index) {
    double? r;
    if (index == 0) {
      // Original aspect ratio.
      r = _turned.width / _turned.height;
    } else if (index == 1) {
      // Square.
      r = 1.0;
    } else {
      // Predefined ratios.
      const ratios = [3 / 2, 5 / 3, 4 / 3, 5 / 4, 7 / 5, 16 / 9];
      if (index >= 2 && index < 2 + ratios.length) {
        r = ratios[index - 2];
      }
    }

    // Presets flip for a portrait photo (Original and Square never do).
    if (index >= 2 && _turned.height > _turned.width && r != null) {
      r = 1 / r;
    }

    setState(() {
      _ratio = r;
      _glide(
        fitRatio(ratio: r!, photoW: _turned.width, photoH: _turned.height),
      );
    });
  }

  /// Chip 0 is Free (no fixed shape); chips 1.. map to [_pickAspect] 0..
  void _selectChip(int c) {
    HapticFeedback.selectionClick();
    setState(() => _chip = c);
    if (c == 0) {
      setState(() => _ratio = null);
    } else {
      _pickAspect(c - 1);
    }
  }

  Future<void> _done() async {
    final image = _image;
    if (image == null || _busy) return;
    setState(() => _busy = true);
    final result = await ref
        .read(photoCropRendererProvider)
        .render(
          widget.source,
          turns: _turns,
          left: _frame.left,
          top: _frame.top,
          right: _frame.right,
          bottom: _frame.bottom,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) {
      showSisNotice(
        context,
        AppLocalizations.of(context).cropUnusable,
        isError: true,
      );
      return;
    }
    Navigator.of(context).pop(result);
  }

  Widget _photoArea() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: LayoutBuilder(
      builder: (context, box) {
        final t = _turned;
        final fit = math.min(box.maxWidth / t.width, box.maxHeight / t.height);
        final ps = Size(t.width * fit, t.height * fit);
        final oldFit = _prevTurned == Size.zero
            ? fit
            : math.min(
                box.maxWidth / _prevTurned.width,
                box.maxHeight / _prevTurned.height,
              );
        final origin = Offset(
          (box.maxWidth - ps.width) / 2,
          (box.maxHeight - ps.height) / 2,
        );
        final px = Rect.fromLTRB(
          _frame.left * ps.width,
          _frame.top * ps.height,
          _frame.right * ps.width,
          _frame.bottom * ps.height,
        );
        return GestureDetector(
          key: const ValueKey('crop-free-area'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            _limitBuzzed = false;
            _grab = grabAt(d.localPosition - origin, px);
            setState(() => _grid = true);
          },
          onPanUpdate: (d) {
            final next = dragFrame(
              frame: _frame,
              grab: _grab,
              delta: d.delta,
              photo: ps,
              minSide: 32,
              ratio: _ratio,
            );
            if (next == _frame &&
                d.delta != Offset.zero &&
                _grab != FrameGrab.none &&
                !_limitBuzzed) {
              _limitBuzzed = true;
              HapticFeedback.lightImpact();
            }
            setState(() {
              _move.value = 1; // a drag is direct, no glide
              _frame = next;
            });
          },
          onPanEnd: (_) => setState(() {
            _grab = FrameGrab.none;
            _grid = false;
          }),
          onPanCancel: () => setState(() {
            _grab = FrameGrab.none;
            _grid = false;
          }),
          child: Stack(
            children: [
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: ps.width,
                height: ps.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedBuilder(
                      animation: _spin,
                      builder: (context, _) => CustomPaint(
                        key: const ValueKey('crop-free-photo'),
                        painter: CropPhotoPainter(
                          image: _image!,
                          turns: _turns,
                          spin: const Cubic(
                            0.05,
                            0.7,
                            0.1,
                            1,
                          ).transform(_spin.value),
                          fromScale: oldFit / fit,
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _move,
                      builder: (context, _) {
                        final s = _shown;
                        return TweenAnimationBuilder<double>(
                          tween: Tween(end: _grid ? 1.0 : 0.0),
                          duration: Duration(milliseconds: _grid ? 150 : 200),
                          builder: (context, g, _) => CustomPaint(
                            key: const ValueKey('crop-free-frame'),
                            painter: CropFramePainter(
                              frame: Rect.fromLTRB(
                                s.left * ps.width,
                                s.top * ps.height,
                                s.right * ps.width,
                                s.bottom * ps.height,
                              ),
                              veil: SisBrand.of(context).background
                                  .withValues(alpha: 0.72),
                              gridOpacity: g,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final brand = SisBrand.of(context);
    final portrait = _turned.height > _turned.width;
    String ratio(String s) => portrait ? s.split(':').reversed.join(':') : s;
    final labels = [
      l.cropFree,
      l.cropOriginal,
      l.cropSquare,
      ratio('3:2'),
      ratio('5:3'),
      ratio('4:3'),
      ratio('5:4'),
      ratio('7:5'),
      ratio('16:9'),
    ];
    const curve = Cubic(0.05, 0.7, 0.1, 1);
    final enter = CurvedAnimation(parent: _enter, curve: curve);
    return Scaffold(
      backgroundColor: brand.background,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: _failed
                  ? Center(
                      child: Text(
                        l.photoOpenFailed,
                        style: TextStyle(color: brand.muted),
                      ),
                    )
                  : _image == null
                  ? const SizedBox.shrink()
                  : FadeTransition(
                      opacity: enter,
                      child: ScaleTransition(
                        scale: Tween(begin: 0.97, end: 1.0).animate(enter),
                        child: _photoArea(),
                      ),
                    ),
            ),
          ),
          FadeTransition(
            opacity: enter,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.25),
                end: Offset.zero,
              ).animate(enter),
              child: CropDock(
                children: [
                  CropChipRow(
                    labels: labels,
                    selected: _chip,
                    onSelect: _selectChip,
                  ),
                  CropActionRow(
                    cancelLabel: l.cropCancel,
                    doneLabel: l.cropDone,
                    resetLabel: l.cropReset,
                    rotateLabel: l.cropRotateLabel,
                    changed: _changed,
                    canDone: _image != null && !_busy,
                    onCancel: () => Navigator.of(context).pop(),
                    onDone: _done,
                    onRotate: _rotate,
                    onReset: _reset,
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

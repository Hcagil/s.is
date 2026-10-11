import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'sticker_draft.dart';

/// Renders the finished sticker at 512 x 512 as straight RGBA bytes, or null if it fails.
Future<Uint8List?> renderStickerRgba(StickerDraft draft) async {
  final effectiveCut = draft.cutOut && draft.mask != null ? 1.0 : 0.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  StickerPainter(draft, cut: effectiveCut).paint(canvas, const Size(512, 512));
  final picture = recorder.endRecording();
  final image = await picture.toImage(512, 512);
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  picture.dispose();
  image.dispose();
  return data?.buffer.asUint8List();
}

class StickerPainter extends CustomPainter {
  /// Creates a sticker painter.
  ///
  /// [draft] the sticker draft to paint
  /// [cut] 0 = whole image, 1 = cut-out, between = fade
  /// [overlays] draw pen strokes and text
  StickerPainter(this.draft, {this.cut = 0, this.overlays = true})
    : super(repaint: draft);

  final StickerDraft draft;

  /// 0 = whole image, 1 = cut-out, between = fade.
  final double cut;

  /// draw pen strokes and text.
  final bool overlays;

  @override
  void paint(Canvas canvas, Size size) {
    final photo = draft.photo;
    if (photo == null) return;
    canvas.save();
    canvas.scale(size.width / stickerSpace);
    const bounds = Rect.fromLTWH(-10, -10, 220, 220);
    final src = Rect.fromLTWH(
      0,
      0,
      photo.width.toDouble(),
      photo.height.toDouble(),
    );
    const dst = Rect.fromLTWH(0, 0, stickerSpace, stickerSpace);
    if (cut < 1) {
      canvas.drawImageRect(
        photo,
        src,
        dst,
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, 1 - cut)
          ..filterQuality = FilterQuality.medium,
      );
    }
    if (cut > 0) {
      canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, cut));
      for (var i = 0; i < 8; i++) {
        final angle = i * math.pi / 4;
        canvas.saveLayer(
          bounds,
          Paint()
            ..colorFilter = const ColorFilter.mode(
              Color(0xFFFFFFFF),
              BlendMode.srcIn,
            ),
        );
        canvas.translate(math.cos(angle) * 3, math.sin(angle) * 3);
        _subject(canvas, photo, src, dst);
        canvas.restore();
      }
      _subject(canvas, photo, src, dst);
      canvas.restore();
    }
    if (overlays) {
      for (final s in draft.pen) {
        _stroke(canvas, s, Paint()..color = s.colour);
      }
      for (final t in draft.texts) {
        if (t.text.trim().isNotEmpty) _text(canvas, t);
      }
    }
    canvas.restore();
  }

  void _subject(Canvas canvas, ui.Image photo, Rect src, Rect dst) {
    canvas.saveLayer(dst.inflate(10), Paint());
    canvas.drawImageRect(
      photo,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final mask = draft.mask;
    if (mask != null) {
      canvas.drawImageRect(
        mask,
        Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
        dst,
        Paint()..blendMode = BlendMode.dstIn,
      );
    }
    for (final s in draft.brush) {
      if (s.erase) {
        _stroke(canvas, s, Paint()..blendMode = BlendMode.clear);
      } else {
        final shader = ImageShader(
          photo,
          TileMode.clamp,
          TileMode.clamp,
          (Matrix4.diagonal3Values(
            stickerSpace / photo.width,
            stickerSpace / photo.height,
            1,
          )).storage,
        );
        _stroke(canvas, s, Paint()..shader = shader);
      }
    }
    canvas.restore();
  }

  void _stroke(Canvas canvas, MakerStroke s, Paint paint) {
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (s.points.length == 1) {
      canvas.drawPoints(ui.PointMode.points, s.points, paint);
      return;
    }
    final path = Path();
    path.moveTo(s.points.first.dx, s.points.first.dy);
    for (var i = 1; i < s.points.length; i++) {
      path.lineTo(s.points[i].dx, s.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  void _text(Canvas canvas, MakerText t) {
    final family = switch (t.font) {
      MakerFont.sans => null,
      MakerFont.serif => 'serif',
      MakerFont.hand => 'cursive',
    };
    final tp1 = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          fontFamily: family,
          fontSize: t.size,
          fontWeight: FontWeight.w800,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = const Color(0x8C000000),
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    final tp2 = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          fontFamily: family,
          fontSize: t.size,
          fontWeight: FontWeight.w800,
          color: t.colour,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    tp1.layout();
    tp2.layout();
    final offset = t.position - Offset(tp1.width / 2, tp1.height / 2);
    tp1.paint(canvas, offset.translate(0, 0));
    tp2.paint(canvas, offset.translate(0, 0));
  }

  @override
  bool shouldRepaint(StickerPainter old) =>
      old.cut != cut || old.overlays != overlays || old.draft != draft;
}

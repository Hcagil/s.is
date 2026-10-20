// Fakes for the photo crop boundary (PhotoCropRenderer), written by QA from
// the interface only.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/photo_crop_renderer.dart';

typedef Cut = ({
  PickedImage source,
  int turns,
  double left,
  double top,
  double right,
  double bottom,
});

/// The renderer as the phone has it: it answers a little later, or when the
/// test lets it ([gate]); [answer] null means the photo could not be cut.
class RendererFake implements PhotoCropRenderer {
  RendererFake({this.answer});
  PickedImage? answer;
  Completer<void>? gate;
  final cuts = <Cut>[];

  @override
  Future<PickedImage?> render(
    PickedImage source, {
    required int turns,
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) async {
    cuts.add((
      source: source,
      turns: turns,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (gate != null) await gate!.future;
    return answer;
  }
}

Future<Uint8List> png(int w, int h) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3366AA),
  );
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

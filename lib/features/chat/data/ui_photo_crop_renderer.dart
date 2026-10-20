import 'dart:math' as math;
import 'dart:ui' as ui;

import '../domain/attachment.dart';
import '../domain/photo_crop_renderer.dart';

/// [PhotoCropRenderer] over the engine's own image codec: decodes the photo,
/// turns it, cuts the frame out and encodes a PNG. Thin on purpose
/// (ARCHITECTURE rule 4): a real render is covered by one test with real
/// pixels.
final class UiPhotoCropRenderer implements PhotoCropRenderer {
  /// Creates the renderer.
  const UiPhotoCropRenderer();

  @override
  Future<PickedImage?> render(
    PickedImage source, {
    required int turns,
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(source.bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      image = img;

      final t = turns % 4;
      final odd = t.isOdd;
      final rw = (odd ? img.height : img.width).toDouble();
      final rh = (odd ? img.width : img.height).toDouble();
      final src = ui.Rect.fromLTRB(
        left * rw,
        top * rh,
        right * rw,
        bottom * rh,
      );

      final scale = math.min(1.0, 2048 / math.max(src.width, src.height));
      final outW = math.max(1, (src.width * scale).round());
      final outH = math.max(1, (src.height * scale).round());

      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.scale(scale);
      canvas.translate(-src.left, -src.top);
      canvas.translate(rw / 2, rh / 2);
      canvas.rotate(-t * math.pi / 2);
      canvas.drawImage(
        img,
        ui.Offset(-img.width / 2, -img.height / 2),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final pic = rec.endRecording();
      final out = await pic.toImage(outW, outH);
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      pic.dispose();
      out.dispose();
      return data == null
          ? null
          : PickedImage(
              bytes: data.buffer.asUint8List(),
              contentType: 'image/png',
              extension: 'png',
              photoGroup: source.photoGroup,
            );
    } catch (_) {
      // Platform codec failures only; null is the documented answer and the
      // screen turns it into a notice.
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}

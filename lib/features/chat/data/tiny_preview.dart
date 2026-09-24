import 'dart:typed_data';
import 'dart:ui' as ui;

/// A tiny PNG of [bytes] (an encoded image), [width] pixels wide, for the
/// blurred preview a receiver sees before the photo arrives. Null when the
/// image cannot be decoded: a missing preview only means the receiver waits.
Future<Uint8List?> tinyPreview(Uint8List bytes, {int width = 24}) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: width);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (e) {
    return null;
  }
}

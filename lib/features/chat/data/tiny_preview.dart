import 'dart:typed_data';
import 'dart:ui' as ui;

/// A tiny PNG of [bytes] (an encoded image), [width] pixels wide, for the
/// blurred preview a receiver sees before the photo arrives. Null when the
/// image cannot be decoded or no preview fits in 2900 bytes: the database
/// refuses a preview over 4000 base64 characters (about 2997 bytes), and a
/// busy photo at 24 pixels can exceed that, which would fail the whole send.
/// A missing preview only means the receiver waits.
Future<Uint8List?> tinyPreview(Uint8List bytes, {int width = 24}) async {
  for (final w in [width, 16, 12, 8]) {
    final png = await _png(bytes, w);
    if (png != null && png.length <= 2900) return png;
  }
  return null;
}

Future<Uint8List?> _png(Uint8List bytes, int width) async {
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

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:imcodec/imcodec.dart' as img;

const _maxPixels = 40000000; // 40 megapixels

/// Shrinks a downloaded picture to a JPEG card picture: at most [width] pixels wide (never enlarged) and at most [maxBytes] bytes. Null when it cannot be decoded or no quality fits.
Future<Uint8List?> shrinkLinkImage(
  Uint8List bytes, {
  int width = 600,
  int maxBytes = 262144,
}) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // Read the claimed size first: a tiny file can claim a huge picture.
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final tooBig = descriptor.width * descriptor.height > _maxPixels;
    descriptor.dispose();
    if (tooBig) {
      buffer.dispose();
      return null;
    }
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int w, int h) => w > width
          ? ui.TargetImageSize(width: width)
          : ui.TargetImageSize(width: w, height: h),
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    final w = frame.image.width;
    final h = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: data.buffer,
      bytesOffset: data.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    for (final q in [80, 65, 50, 35]) {
      final out = img.encodeJpg(
        image,
        options: img.JpegEncodeOptions(quality: q),
      );
      if (out.length <= maxBytes) return out;
    }
    return null;
  } catch (_) {
    return null;
  }
}

import 'dart:isolate';
import 'dart:typed_data';

import 'package:imcodec/imcodec.dart' as img;

import '../domain/sticker_maker.dart';

/// [StickerEncoder] in pure Dart: iOS has no WebP encoder of its own, and a
/// CocoaPods plugin would not fit this SwiftPM-only project. Lossless WebP
/// first (this package's lossy WebP stores alpha uncompressed), then lossy
/// with the quality lowered until the file fits [stickerMaxBytes].
final class ImcodecStickerEncoder implements StickerEncoder {
  const ImcodecStickerEncoder();

  @override
  Future<Uint8List?> encode(Uint8List rgba) async {
    if (rgba.length != stickerSide * stickerSide * 4) return null;
    try {
      return await Isolate.run(() => _encode(rgba));
    } on Object {
      return null;
    }
  }
}

Uint8List? _encode(Uint8List rgba) {
  final image = img.Image.fromBytes(
    width: stickerSide,
    height: stickerSide,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  final lossless = img.encodeWebP(
    image,
    options: const img.WebPEncodeOptions(),
  );
  if (lossless.length <= stickerMaxBytes) return lossless;
  for (final q in const [90, 80, 70, 60, 50, 40, 30, 20]) {
    final out = img.encodeWebP(
      image,
      options: img.WebPEncodeOptions(quality: q),
    );
    if (out.length <= stickerMaxBytes) return out;
  }
  return null;
}

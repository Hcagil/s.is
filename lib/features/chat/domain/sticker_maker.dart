import 'dart:typed_data';

/// Side of a sticker image in pixels (square).
const int stickerSide = 512;

/// Largest sticker image the server accepts, in bytes.
const int stickerMaxBytes = 102400;

/// Removes the background of a sticker photo on the phone (Android ML Kit subject segmentation, iOS Vision subject lifting). Its own boundary because it is a platform capability.
abstract interface class StickerCutter {
  /// Whether this phone can cut out subjects at all; false hides the "Cut-out" choice. Never throws.
  Future<bool> supported();

  /// [jpeg] is the square photo ([stickerSide] x [stickerSide]). Returns stickerSide*stickerSide bytes, row-major, one byte per pixel: 0 = background, 255 = subject. Null when there is no subject, the model is not ready yet, or anything failed. Never throws.
  Future<Uint8List?> mask(Uint8List jpeg);
}

/// Turns the finished sticker pixels into the WebP the server stores.
abstract interface class StickerEncoder {
  /// [rgba] is [stickerSide] x [stickerSide] straight (not premultiplied) RGBA, 4 bytes per pixel. Returns a WebP with transparency of at most [stickerMaxBytes] bytes, or null when no quality setting fits. Never throws.
  Future<Uint8List?> encode(Uint8List rgba);
}

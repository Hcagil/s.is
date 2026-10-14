import 'dart:typed_data';

import '../domain/sticker_maker.dart';

/// The platform cut-out (ML Kit, Vision) first; the bundled model only when
/// the platform one is unavailable or returns nothing.
final class FallbackStickerCutter implements StickerCutter {
  const FallbackStickerCutter(this.primary, this.fallback);

  final StickerCutter primary;
  final StickerCutter fallback;

  @override
  Future<bool> supported() async =>
      await primary.supported() || await fallback.supported();

  @override
  Future<Uint8List?> mask(Uint8List jpeg) async {
    if (await primary.supported()) {
      final m = await primary.mask(jpeg);
      if (m != null) return m;
    }
    return fallback.mask(jpeg);
  }
}

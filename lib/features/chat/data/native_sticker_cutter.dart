import 'package:flutter/services.dart';

import '../domain/sticker_maker.dart';

/// [StickerCutter] over the same platform channel as `ExternalPickerChannel`:
/// asks the native side for a cut-out mask of a JPEG photo (Android ML Kit,
/// iOS Vision). Thin on purpose (ARCHITECTURE rule 4): verified on a device,
/// not by a unit test.
final class NativeStickerCutter implements StickerCutter {
  const NativeStickerCutter({
    MethodChannel channel = const MethodChannel('sis/external_picker'),
    // ignore: prefer_initializing_formals
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> supported() async {
    try {
      return await _channel.invokeMethod<bool>('cutoutSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<Uint8List?> mask(Uint8List jpeg) async {
    try {
      final result = await _channel.invokeMethod<Uint8List>('cutoutMask', {
        'bytes': jpeg,
      });
      if (result == null || result.length != stickerSide * stickerSide) {
        return null;
      }
      return result;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

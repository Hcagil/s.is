import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/attachment.dart';
import '../domain/picture_cropper.dart';

/// [PictureCropper] over the same platform channel as `ExternalPickerChannel`:
/// writes [source] to a temporary file so the native side can read it by
/// path, asks it to crop, scale and JPEG-encode, then reads the result back
/// and deletes both temporary files. Thin on purpose (ARCHITECTURE rule 4):
/// verified on a device, not by a unit test.
final class NativePictureCropper implements PictureCropper {
  const NativePictureCropper({
    MethodChannel channel = const MethodChannel('sis/external_picker'),
    // ignore: prefer_initializing_formals
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<PickedImage?> crop(
    Uint8List source, {
    required double left,
    required double top,
    required double right,
    required double bottom,
    int size = 640,
    int quality = 82,
  }) async {
    final dir = await getTemporaryDirectory();
    final input = File(
      '${dir.path}/crop_in_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      await input.writeAsBytes(source);
    } on FileSystemException {
      return null;
    }
    String? outputPath;
    try {
      outputPath = await _channel.invokeMethod<String>('cropPicture', {
        'path': input.path,
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'size': size,
        'quality': quality,
      });
    } on PlatformException {
      outputPath = null;
    } finally {
      try {
        await input.delete();
      } on FileSystemException {
        // Cache cleanup only.
      }
    }
    if (outputPath == null) return null;
    final output = File(outputPath);
    try {
      final bytes = await output.readAsBytes();
      return PickedImage(
        bytes: bytes,
        contentType: 'image/jpeg',
        extension: 'jpg',
      );
    } on FileSystemException {
      return null;
    } finally {
      try {
        await output.delete();
      } on FileSystemException {
        // Cache cleanup only.
      }
    }
  }
}

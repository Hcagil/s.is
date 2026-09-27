import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/attachment.dart';
import '../domain/external_picker.dart';
import 'tiny_preview.dart';

/// [ExternalPicker] over a platform channel to the Android host
/// (MainActivity.kt): it starts Android's own app chooser, copies whatever
/// comes back into this app's cache right away -- a content URI's read
/// grant is temporary -- and hands back file paths already processed to the
/// shape [ExternalPicker] promises (long-edge-1600 or 512 centre-crop JPEG).
/// This class only reads those files into memory and deletes them; no image
/// processing happens in Dart. Thin on purpose (ARCHITECTURE rule 4):
/// verified on a device, not by a unit test.
final class ExternalPickerChannel implements ExternalPicker {
  // A named (not initializing-formal) parameter on purpose: `channel` is the
  // public seam a test overrides; `_channel` stays private.
  const ExternalPickerChannel({
    MethodChannel channel = const MethodChannel('sis/external_picker'),
    // ignore: prefer_initializing_formals
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<ExternalPickResult> pickAttachments() =>
      _pick('pickAttachments', withPreview: true);

  @override
  Future<ExternalPickResult> pickProfilePicture() =>
      _pick('pickProfilePicture', withPreview: false);

  /// [method] answers with a list of file paths, an empty/null list when the
  /// member cancelled, or throws a [PlatformException] (codes: `not_image`,
  /// `unreadable`, `no_app`, `busy`) when what came back could not be used.
  Future<ExternalPickResult> _pick(
    String method, {
    required bool withPreview,
  }) async {
    final List<Object?>? paths;
    try {
      paths = await _channel.invokeMethod<List<Object?>>(method);
    } on PlatformException {
      return const ExternalPickFailed();
    }
    if (paths == null || paths.isEmpty) return const ExternalPickCancelled();
    final images = <PickedImage>[];
    for (final entry in paths) {
      final file = File(entry! as String);
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException {
        return const ExternalPickFailed();
      }
      images.add(
        PickedImage(
          bytes: bytes,
          contentType: 'image/jpeg',
          extension: 'jpg',
          preview: withPreview ? await tinyPreview(bytes) : null,
        ),
      );
      try {
        await file.delete();
      } on FileSystemException {
        // Cache cleanup only; a missed delete costs disk, not correctness.
      }
    }
    return ExternalPickedImages(images);
  }
}

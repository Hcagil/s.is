import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/attachment.dart';
import '../domain/external_picker.dart';
import 'tiny_preview.dart';

/// [ExternalPicker] over a platform channel to the host app: MainActivity.kt
/// on Android starts the system app chooser, ExternalPickerPlugin.swift on
/// iOS opens the system photo picker (PHPicker). Either way the host copies
/// whatever comes back into this app's cache right away -- Android's content
/// URI read grant is temporary -- and hands back file paths already
/// processed to the shape [ExternalPicker] promises (long-edge-1600 for an
/// attachment, long-edge-2048 for a picture's crop source).
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
  Future<ExternalPickResult> pickAttachments() async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('pickAttachments');
    } on PlatformException catch (e) {
      log('picker ${e.code}: ${e.message}', name: 'sis.chat', error: e);
      return const ExternalPickFailed();
    }
    if (raw == null) return const ExternalPickCancelled();
    final paths = raw['paths'] as List<Object?>?;
    if (paths == null || paths.isEmpty) return const ExternalPickCancelled();
    final dropped = raw['dropped'] as int? ?? 0;
    final images = await _readFiles(paths, withPreview: true);
    if (images == null) return const ExternalPickFailed();
    return ExternalPickedImages(images, dropped: dropped);
  }

  @override
  Future<ExternalPickResult> pickProfilePicture() async {
    final List<Object?>? paths;
    try {
      paths = await _channel.invokeMethod<List<Object?>>('pickProfilePicture');
    } on PlatformException catch (e) {
      log('picker ${e.code}: ${e.message}', name: 'sis.chat', error: e);
      return const ExternalPickFailed();
    }
    if (paths == null || paths.isEmpty) return const ExternalPickCancelled();
    final images = await _readFiles(paths, withPreview: false);
    if (images == null) return const ExternalPickFailed();
    return ExternalPickedImages(images);
  }

  /// Reads every path in [paths] into a [PickedImage], deleting each file
  /// once read. Null when any file could not be read -- the whole pick is
  /// then treated as failed, never partially sent.
  Future<List<PickedImage>?> _readFiles(
    List<Object?> paths, {
    required bool withPreview,
  }) async {
    final images = <PickedImage>[];
    try {
      for (final entry in paths) {
        final file = File(entry! as String);
        final Uint8List bytes;
        try {
          bytes = await file.readAsBytes();
        } on FileSystemException catch (e) {
          log('picked file unreadable: $e', name: 'sis.chat', error: e);
          return null;
        }
        images.add(
          PickedImage(
            bytes: bytes,
            contentType: 'image/jpeg',
            extension: 'jpg',
            preview: withPreview ? await tinyPreview(bytes) : null,
          ),
        );
      }
    } finally {
      for (final entry in paths) {
        try {
          await File(entry! as String).delete();
        } on FileSystemException {
          // Cache cleanup only; a missed delete costs disk, not correctness.
        }
      }
    }
    return images;
  }
}

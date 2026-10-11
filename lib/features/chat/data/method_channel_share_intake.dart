import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/attachment.dart';
import '../domain/shared_content.dart';
import 'tiny_preview.dart';

/// [ShareIntake] over the platform channel `sis/share_intake` to the host app
/// (MainActivity.kt on Android, ShareIntakePlugin.swift on iOS). The host copies
/// what another app shared into this app's cache and answers `take` with a map
/// {'text': String?, 'items': [{'path', 'name', 'video': bool}]} or null when
/// nothing waits; it calls `arrived` on the channel when a share reaches the
/// already running app. Thin on purpose: verified on a device, not by a unit
/// test.
final class MethodChannelShareIntake implements ShareIntake {
  /// Creates the intake; [channel] is the seam a test overrides.
  MethodChannelShareIntake({
    MethodChannel channel = const MethodChannel('sis/share_intake'),
    // ignore: prefer_initializing_formals
  }) : _channel = channel {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<void> _arrivals = StreamController<void>.broadcast();

  @override
  Stream<void> get arrivals => _arrivals.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method == 'arrived') _arrivals.add(null);
  }

  @override
  Future<SharedContent?> take() async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>('take');
    } on PlatformException {
      log('share intake failed', name: 'sis.chat');
      return null;
    } on MissingPluginException {
      log('share intake failed', name: 'sis.chat');
      return null;
    }
    if (raw == null) return null;
    final rawItems = raw['items'] as List<Object?>? ?? const [];
    final content = SharedContent(
      text: (raw['text'] as String?) ?? '',
      items: [
        for (final entry in rawItems)
          SharedItem(
            path: (entry! as Map<Object?, Object?>)['path']! as String,
            name: (entry as Map<Object?, Object?>)['name']! as String,
            isVideo: entry['video'] == true,
          ),
      ],
    );
    return content.isEmpty ? null : content;
  }

  @override
  Future<PickedImage?> readPhoto(SharedItem item) async {
    try {
      final bytes = await File(item.path).readAsBytes();
      return PickedImage(
        bytes: bytes,
        contentType: 'image/jpeg',
        extension: 'jpg',
        preview: await tinyPreview(bytes),
      );
    } on FileSystemException {
      log('shared photo unreadable', name: 'sis.chat');
      return null;
    }
  }

  @override
  Future<void> discard(SharedContent content) async {
    for (final item in content.items) {
      try {
        await File(item.path).delete();
      } on FileSystemException {
        // Cache cleanup only; a missed delete costs disk, not correctness.
      }
    }
  }
}

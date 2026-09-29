import 'package:flutter/services.dart';

import '../domain/alert_settings.dart';

/// [TonePicker] over a platform channel to the Android host (MainActivity.kt),
/// which opens the phone's own notification-sound chooser. Thin on purpose
/// (ARCHITECTURE rule 4): verified on a device.
final class ChannelTonePicker implements TonePicker {
  // A named (not initializing-formal) parameter on purpose: `channel` is the
  // public seam a test overrides; `_channel` stays private.
  const ChannelTonePicker({
    MethodChannel channel = const MethodChannel('sis/tone_picker'),
    // ignore: prefer_initializing_formals
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<PickedTone?> pick(String? currentTone) async {
    final Map<String, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('pick', {
        'current': currentTone,
      });
    } on PlatformException {
      return null;
    }
    // Null: the member cancelled. A null uri: they chose the system default.
    if (raw == null) return null;
    return PickedTone(
      tone: raw['uri'] as String?,
      name: raw['name'] as String? ?? 'Custom',
    );
  }
}

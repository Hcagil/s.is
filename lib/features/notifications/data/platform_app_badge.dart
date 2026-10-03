import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/push.dart';

/// The app-icon number. iOS sets it through AppDelegate.swift; Android has no
/// app-set number (its launcher badge follows the notification, which
/// InstantPush.kt numbers from the push).
final class PlatformAppBadge implements AppBadge {
  const PlatformAppBadge();

  static const _channel = MethodChannel('sis/notifications');

  @override
  Future<void> set(int count) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('setBadge', count < 0 ? 0 : count);
    } on PlatformException {
      // A badge is cosmetic: never a failure.
    } on MissingPluginException {
      // No native side (a test host).
    }
  }
}

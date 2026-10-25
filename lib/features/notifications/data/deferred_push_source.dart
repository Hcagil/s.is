import 'package:flutter/services.dart';

import '../domain/push.dart';

/// Push channel whose Firebase setup finishes after the first frame
/// (main.dart): every call waits for it, so nothing is lost -- a cold-start
/// notification tap is still read, just after the setup, and a failed setup
/// surfaces as the error of each call.
final class DeferredPushSource implements PushSource {
  DeferredPushSource(this._ready);

  static const _launchTap = MethodChannel('sis/launch_tap');

  final Future<PushSource> _ready;

  @override
  Future<bool> requestPermission() async => (await _ready).requestPermission();

  @override
  Future<PushPermissionStatus> permissionStatus() async =>
      (await _ready).permissionStatus();

  @override
  Future<String?> token() async => (await _ready).token();

  @override
  Stream<String> get tokenRefreshes async* {
    yield* (await _ready).tokenRefreshes;
  }

  /// Android hands the chat id of a cold-start notification tap over at once
  /// (MainActivity, channel `sis/launch_tap`), so the chat opens without
  /// waiting for Firebase. Other platforms, or no tap: the Firebase source.
  @override
  Future<String?> launchConversation() async {
    try {
      final early = await _launchTap.invokeMethod<String>('take');
      if (early != null && early.isNotEmpty) return early;
    } catch (_) {
      // No native side here (iOS, tests): fall through.
    }
    return (await _ready).launchConversation();
  }

  @override
  Stream<String> get openedConversations async* {
    yield* (await _ready).openedConversations;
  }

  @override
  Future<void> clearConversation(String conversationId) async =>
      (await _ready).clearConversation(conversationId);

  @override
  Future<void> clearAll() async => (await _ready).clearAll();

  @override
  Future<void> forUser(String? userId) async => (await _ready).forUser(userId);
}

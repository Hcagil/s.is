import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/push.dart';

/// The device's push channel (Firebase Messaging in data/).
final pushSourceProvider = Provider<PushSource>(
  (_) => throw UnimplementedError('override in main'),
);

/// The server's list of where to deliver.
final pushRegistryProvider = Provider<PushRegistry>(
  (_) => throw UnimplementedError('override in main'),
);

/// Keeps this device on the server's delivery list for whoever is signed in;
/// state is the token last registered for the current account, or null.
final pushRegistrationProvider = NotifierProvider<PushRegistration, String?>(
  PushRegistration.new,
);

class PushRegistration extends Notifier<String?> {
  @override
  String? build() {
    final me = ref.watch(currentUserIdProvider);
    if (me == null) return null;

    final source = ref.read(pushSourceProvider);
    final sub = source.tokenRefreshes.listen(_register);
    ref.onDispose(sub.cancel);

    unawaited(_start());
    return null;
  }

  Future<void> _start() async {
    final source = ref.read(pushSourceProvider);
    // Registered even when refused: the member can allow notifications later
    // in system settings, and the server then already knows the device.
    await source.requestPermission();
    final token = await source.token();
    if (token != null) await _register(token);
  }

  /// A failed registration is not shown anywhere: it is retried on the next
  /// start and on the next token refresh.
  Future<void> _register(String token) async {
    if (!ref.mounted) return;
    final r = await ref.read(pushRegistryProvider).register(token);
    if (r is Ok && ref.mounted) state = token;
  }

  /// Called before signing out, while the session can still reach the server:
  /// stops this device receiving the member's notifications.
  ///
  /// Best effort -- if it fails, the server still sends nothing to a device
  /// whose session has ended.
  Future<void> forget() async {
    final source = ref.read(pushSourceProvider);
    final token = state ?? await source.token();
    if (token != null) await ref.read(pushRegistryProvider).forget(token);
    // Nothing of this account stays in the notification shade.
    await source.clearAll();
  }
}

/// Conversations the member opened by tapping a notification -- the one that
/// launched the app, then each later tap.
final openedFromNotificationProvider = StreamProvider<String>((ref) async* {
  final source = ref.read(pushSourceProvider);
  final first = await source.launchConversation();
  if (first != null) yield first;
  yield* source.openedConversations;
});

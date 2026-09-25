import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/push.dart';

/// The device's push channel (Firebase Messaging in data/).
final pushSourceProvider = Provider<PushSource>(
  (_) => throw UnimplementedError('override in main'),
);

/// The server's list of where to deliver.
final pushRegistryProvider = Provider<PushRegistry>(
  (_) => throw UnimplementedError('override in main'),
);

/// Tells the push source who owns what it keeps on this device (the shade
/// and the stored inbox), from every settled answer about the session --
/// not only from home: a cold start that ends on the sign-in or Denied
/// screen must drop the previous member's notifications too. While the
/// session is still being (re)checked nobody has changed, so nothing is
/// told: a start offline must not wipe the member's own inbox.
final pushInboxOwnerProvider = Provider<void>((ref) {
  final source = ref.read(pushSourceProvider);
  ref.listen(sessionControllerProvider, (_, next) {
    switch (next.value) {
      case Allowed(:final member):
        unawaited(source.forUser(member.userId));
      case SignedOut() || Denied():
        unawaited(source.forUser(null));
      case _:
    }
  }, fireImmediately: true);
});

/// Keeps this device on the server's delivery list for whoever is signed in;
/// state is the token last registered for the current account, or null.
final pushRegistrationProvider = NotifierProvider<PushRegistration, String?>(
  PushRegistration.new,
);

class PushRegistration extends Notifier<String?> {
  @override
  String? build() {
    // Before anything is registered: what a previous member left must be
    // gone before the first push for this one can arrive.
    ref.watch(pushInboxOwnerProvider);
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
    // Permission is asked for by NotificationExplainer, after the member has
    // seen why -- never here. Registration itself does not depend on it:
    // even refused, the server already knows the device, and can reach it
    // if the member allows notifications later in system settings.
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

/// Where "the explainer was shown" is persisted (shared_preferences in
/// data/).
final notificationExplainerStoreProvider = Provider<NotificationExplainerStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// True when NotificationExplainerScreen should be skipped: already shown
/// before, or -- an existing install from before this screen existed, or a
/// member who granted the permission some other way -- the platform already
/// has an answer that needs no explaining. Starts as loading (AsyncLoading),
/// so nothing shows the explainer before this settles.
final notificationExplainerShownProvider = FutureProvider<bool>((ref) async {
  final store = ref.read(notificationExplainerStoreProvider);
  if (await store.wasShown()) return true;
  final status = await ref.read(pushSourceProvider).permissionStatus();
  if (status == PushPermissionStatus.authorized ||
      status == PushPermissionStatus.provisional) {
    // Nothing to explain: the member already answered. Recorded so this
    // platform round trip only ever happens once.
    await store.markShown();
    return true;
  }
  return false;
});

/// Marks the explainer shown and only then asks the platform for
/// notification permission -- the one place `requestPermission` is called.
final notificationExplainerProvider =
    NotifierProvider<NotificationExplainer, void>(NotificationExplainer.new);

class NotificationExplainer extends Notifier<void> {
  @override
  void build() {}

  Future<void> continueAndAskPermission() async {
    await ref.read(notificationExplainerStoreProvider).markShown();
    ref.invalidate(notificationExplainerShownProvider);
    await ref.read(pushSourceProvider).requestPermission();
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

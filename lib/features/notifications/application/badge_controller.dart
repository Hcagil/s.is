import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../../chat/application/chat_controllers.dart';
import '../domain/push.dart';

/// The app-icon number (the platform one in data/). Defaults to nothing so a
/// build without it still runs; main overrides it.
final appBadgeProvider = Provider<AppBadge>((_) => const _NoBadge());

final class _NoBadge implements AppBadge {
  const _NoBadge();
  @override
  Future<void> set(int count) async {}
}

/// Keeps the app-icon number equal to the server's unread total (muted chats
/// and people left out), for whoever is signed in; a signed-out phone shows
/// none.
///
/// Off the user path: the read is debounced and nothing waits on it. It runs
/// when the chat list's unread numbers change (a chat read here or on
/// another device, a message arriving, a delete) and when the returned
/// function is called, which the app does on every return to the screen --
/// so the number is corrected the moment the app is opened, never left stale.
/// A failed read leaves the number as it was. A session still restoring, or
/// one that failed, is not a sign-out and sets nothing; a signed-out or
/// denied member gets 0.
final badgeSyncProvider = Provider<void Function()>((ref) {
  final me = ref.watch(currentUserIdProvider);
  if (me == null) {
    final noAccess = ref.watch(
      sessionControllerProvider.select(
        (s) => s.value is SignedOut || s.value is Denied,
      ),
    );
    if (noAccess) {
      Future.microtask(() => ref.read(appBadgeProvider).set(0));
    }
    return () {};
  }

  Timer? debounce;
  ref.onDispose(() => debounce?.cancel());

  Future<void> run() async {
    final r = await ref.read(chatRepositoryProvider).unreadTotal();
    if (!ref.mounted) return;
    if (r case Ok(:final value)) {
      await ref.read(appBadgeProvider).set(value);
    }
  }

  void schedule() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 800), () => unawaited(run()));
  }

  ref.listen(
    conversationListProvider.select(
      (l) => l.value?.fold<int>(0, (a, c) => a + c.unread),
    ),
    (_, _) => schedule(),
    fireImmediately: true,
  );

  return schedule;
});

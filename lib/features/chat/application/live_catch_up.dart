part of 'chat_controllers.dart';

/// Fetches what Realtime missed, the moment something says it was missed:
/// a Realtime channel that re-joined after a dropped connection (the phone's
/// store, the open chat and the chat list read again), and a push that
/// arrives while the app is open (that chat's newest rows are read once).
/// Rows are merged by id, so a row Realtime also delivers is never doubled.
/// Watched once from the app shell (app/sis_app.dart).
final liveCatchUpProvider = Provider<void>((ref) {
  void everything() {
    if (ref.read(sessionControllerProvider).value is! Allowed) return;
    unawaited(ref.read(storeSyncProvider).run());
    if (ref.read(openConversationProvider) != null) {
      ref.read(messagesProvider.notifier).verifyNewest(force: true);
    }
    if (ref.exists(conversationListProvider)) {
      unawaited(ref.read(conversationListProvider.notifier).reloadQuietly());
    }
  }

  void forChat(String conversationId) {
    if (ref.read(sessionControllerProvider).value is! Allowed) return;
    if (ref.read(openConversationProvider) == conversationId) {
      ref.read(messagesProvider.notifier).verifyNewest(force: true);
    } else {
      // The change feed brings that chat's new rows to the phone; the list shows them.
      unawaited(ref.read(storeSyncProvider).run());
    }
    if (ref.exists(conversationListProvider)) {
      unawaited(ref.read(conversationListProvider.notifier).reloadQuietly());
    }
  }

  final rejoin = ref
      .watch(realtimeRejoinedProvider)
      .listen((_) => everything());
  final push = ref.watch(foregroundPushProvider).listen(forChat);
  ref.onDispose(() {
    unawaited(rejoin.cancel());
    unawaited(push.cancel());
  });
});

part of 'chat_controllers.dart';

/// The conversation the message screen is showing, or null on the list screen.
///
/// [MessagesController] watches this, so opening a conversation rebuilds it and
/// closing one tears the Realtime subscription down. A family provider would
/// keep a controller per conversation alive; only one is ever on screen.
final openConversationProvider = NotifierProvider<OpenConversation, String?>(
  OpenConversation.new,
);

class OpenConversation extends Notifier<String?> {
  @override
  String? build() {
    // A new account starts with nothing open.
    ref.watch(currentUserIdProvider);
    return null;
  }

  void open(String conversationId) => state = conversationId;

  void close() => state = null;
}

/// Whether the app is on screen. False from AppLifecycleListener.onHide to
/// onShow (wired in app/sis_app.dart): a message that arrives meanwhile is
/// not marked read -- nobody saw it -- the resume catch-up
/// (resumeCatchUpProvider) marks it when the member returns.
final appVisibleProvider = NotifierProvider<AppVisible, bool>(AppVisible.new);

class AppVisible extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool visible) => state = visible;
}

/// Called when the app comes back to the foreground: the open chat and the
/// chat list fetch what they missed, and the open chat's notification goes
/// (its messages are on screen).
///
/// Those messages are also marked read: this phone's own Realtime listener
/// never heard what arrived while it was backgrounded (iOS suspends the
/// socket at once), so nothing else would tell the sender. The read marks
/// are joined again and re-read too, for the opposite case: a read that
/// happened while THIS phone was backgrounded.
final resumeCatchUpProvider = Provider<void Function()>((ref) {
  return () {
    // Nothing to catch up on before sign-in (and no repository to ask).
    if (ref.read(sessionControllerProvider).value is! Allowed) return;
    final open = ref.read(openConversationProvider);
    final list = ref.read(conversationListProvider.notifier);
    if (open == null) {
      unawaited(list.catchUp());
      return;
    }
    ref.read(messagesProvider.notifier).catchUp();
    unawaited(ref.read(pushSourceProvider).clearConversation(open));
    ref.invalidate(readMarksProvider);
    // Marked first, so the list's re-read sees the count already at zero.
    unawaited(list.markRead(open).then((_) => list.catchUp()));
  };
});

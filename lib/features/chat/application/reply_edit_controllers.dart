part of 'chat_controllers.dart';

/// The message the composer is answering, or null. Cleared when another
/// conversation opens and after the reply is sent.
final replyingToProvider = NotifierProvider<ReplyingTo, Message?>(
  ReplyingTo.new,
);

class ReplyingTo extends Notifier<Message?> {
  @override
  Message? build() {
    ref.watch(openConversationProvider);
    return null;
  }

  void start(Message message) => state = message;

  void clear() => state = null;
}

/// The message being edited in the composer, or null. Cleared when another
/// conversation opens and after the edit is saved or cancelled.
final editingProvider = NotifierProvider<Editing, Message?>(Editing.new);

class Editing extends Notifier<Message?> {
  @override
  Message? build() {
    ref.watch(openConversationProvider);
    return null;
  }

  void start(Message message) => state = message;

  void clear() => state = null;
}

/// The message the member tapped (its "Seen by" pill above and reactions bar below are showing), or null. Tapping the same message again clears it; cleared when another conversation opens.
final tappedMessageProvider =
    NotifierProvider.autoDispose<TappedMessage, String?>(TappedMessage.new);

class TappedMessage extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(openConversationProvider);
    return null;
  }

  /// Taps [messageId]: shows its extras, or hides them when it is already the tapped one.
  void toggle(String messageId) =>
      state = state == messageId ? null : messageId;

  void clear() => state = null;
}

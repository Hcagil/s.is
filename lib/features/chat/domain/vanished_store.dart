/// Id-only tombstones of messages deleted for everyone within the vanish window. Only the message id and its chat id are kept, never any content, so a reply that quotes a vanished message can say "This message was deleted". Separate from MessageStore so existing fakes of MessageStore keep working.
abstract interface class VanishedStore {
  /// Removes the stored message [messageId] (and its notification copy) and remembers only that it vanished from [conversationId]. Never throws.
  Future<void> markVanished(String messageId, String conversationId);

  /// Ids of the vanished messages of [conversationId]. Never throws; an unreadable store gives an empty set.
  Future<Set<String>> vanishedIds(String conversationId);
}

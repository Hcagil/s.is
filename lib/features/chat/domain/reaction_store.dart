/// The opened reactions kept on the phone (encrypted at rest): a locked reaction can be opened only once, so its emoji is saved here keyed by (messageId, userId, sealed) where sealed is the sha256 hex of the row's ciphertext. Reads never throw (empty/null on failure); a closed or erased store skips writes.
abstract interface class ReactionStore {
  /// The emoji saved for exactly this (messageId, userId, sealed), or null.
  Future<String?> emojiOf(String messageId, String userId, String sealed);

  /// Saves [emoji]; replaces any older saved emoji of the same (messageId, userId).
  Future<void> put(
    String messageId,
    String userId,
    String sealed,
    String emoji,
  );

  /// How often [userId] used each emoji in their [limit] newest saved locked reactions.
  Future<Map<String, int>> usageOf(String userId, {int limit = 300});
}

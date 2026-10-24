import 'reaction.dart';

/// Opens locked reactions read from the server, once each, on this phone. Every path that reads reaction rows runs them through [open].
abstract interface class ReactionOpener {
  /// Returns the rows with each locked one (ciphertext not null) replaced by a Reaction holding its emoji (ciphertext cleared), after it was opened exactly once and saved; a locked row that cannot be opened (no session, unreadable, wrong message or user in the envelope, no saved copy for an own row) comes back with emoji null (hidden, never text). Rows without ciphertext pass unchanged. Locked rows are opened oldest first. Never throws.
  Future<List<Reaction>> open(List<Reaction> rows);

  /// Saves the caller's own just-locked reaction so it can be shown later; [ciphertext] is the base64 sent to the server.
  Future<void> rememberOwn(
    String messageId,
    String userId,
    String ciphertext,
    String emoji,
  );

  /// The caller's own locked-reaction usage from the phone (see ReactionStore.usageOf).
  Future<Map<String, int>> ownUsage(String userId);
}

import '../../../core/failure.dart';
import 'reaction.dart';

/// Reactions boundary; the only way the app reaches message reactions. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. Row-level security decides what is returned.
abstract interface class ReactionRepository {
  /// Every current reaction (emoji not null) on the messages of [conversationId] the caller may read, newest change first, capped at 1000. Locked reactions are opened on this phone first; one that cannot be opened is hidden (never shown as text).
  Future<Result<List<Reaction>>> reactions(String conversationId);

  /// Sets the caller's reaction on [messageId] to [emoji], or clears it when null. The caller decides set vs clear (never a toggle on the server), so a retry is harmless. DeniedFailure when the message is not readable to the caller, deleted, or in the system chat; a malformed emoji also fails.
  Future<Result<void>> setReaction(String messageId, String? emoji);

  /// Sets the caller's reaction on [messageId] to an emoji already locked on this phone ([ciphertext], base64 Olm message of type [olmType], 0 or 1): RPC set_reaction_encrypted. The server never sees the emoji. DeniedFailure when the message is not readable, the chat cannot hold ciphertext, or the caller is a bot. Same answers as [setReaction] otherwise.
  Future<Result<void>> setLockedReaction(
    String messageId,
    String ciphertext,
    int olmType,
  );

  /// Reactions changing in [conversationId] as they happen (a null emoji means removed), the caller's own included; resolves once subscribed. Realtime re-checks the read policy per subscriber. Locked reactions are opened first; one that cannot be opened arrives as a removal.
  Future<Result<Stream<Reaction>>> reactionUpdates(String conversationId);

  /// How many times the caller used each emoji, over their most recent 300 reactions; feeds the reactions bar. Locked reactions are counted from this phone's own saved copies.
  Future<Result<Map<String, int>>> myReactionUsage();
}

/// Optional second capability of a [ReactionRepository]: re-locks an OLD plain reaction of the caller (RPC relock_reaction). Compare-and-set on the server: only a row that is still plain is replaced, so a newer change or a removal is never undone. Ok(true) when re-locked, Ok(false) when the row had changed meanwhile.
abstract interface class ReactionRelocker {
  Future<Result<bool>> relockPlain(
    String messageId,
    String ciphertext,
    int olmType,
  );
}

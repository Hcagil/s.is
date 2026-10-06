import '../../../core/failure.dart';
import 'reaction.dart';

/// Reactions boundary; the only way the app reaches message reactions. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. Row-level security decides what is returned.
abstract interface class ReactionRepository {
  /// Every current reaction (emoji not null) on the messages of [conversationId] the caller may read, newest change first, capped at 1000.
  Future<Result<List<Reaction>>> reactions(String conversationId);

  /// Sets the caller's reaction on [messageId] to [emoji], or clears it when null. The caller decides set vs clear (never a toggle on the server), so a retry is harmless. DeniedFailure when the message is not readable to the caller, deleted, or in the system chat; a malformed emoji also fails.
  Future<Result<void>> setReaction(String messageId, String? emoji);

  /// Reactions changing in [conversationId] as they happen (a null emoji means removed), the caller's own included; resolves once subscribed. Realtime re-checks the read policy per subscriber.
  Future<Result<Stream<Reaction>>> reactionUpdates(String conversationId);

  /// How many times the caller used each emoji, over their most recent 300 reactions; feeds the reactions bar.
  Future<Result<Map<String, int>>> myReactionUsage();
}

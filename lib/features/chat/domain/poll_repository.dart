import '../../../core/failure.dart';
import 'poll.dart';

/// Polls boundary; the only way the app reaches poll messages. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. Row-level security decides what is returned.
abstract interface class PollRepository {
  /// Every poll of the messages of [conversationId] the caller may read, with the caller's own choices in Poll.mine.
  Future<Result<List<Poll>>> polls(String conversationId);

  /// One poll by its message id; null inside Ok when the message is no poll or is not readable.
  Future<Result<Poll?>> poll(String messageId);

  /// Creates the poll message [messageId] (a client-generated id: a retry with the same id is harmless) in [conversationId] from [draft]. DeniedFailure when the caller may not post there (not a member, the bot, the system chat).
  Future<Result<void>> createPoll(
    String conversationId,
    String messageId,
    PollDraft draft,
  );

  /// Sets the caller's choice on poll [messageId] to exactly [optionIds]; an empty set retracts. PollClosedFailure when the poll is closed, DeniedFailure when not readable.
  Future<Result<void>> vote(String messageId, Set<String> optionIds);

  /// Closes poll [messageId] for good; only its creator may. DeniedFailure otherwise.
  Future<Result<void>> close(String messageId);

  /// Who chose what on poll [messageId]; empty for an anonymous poll except the caller's own votes (the server never shows others).
  Future<Result<List<PollVote>>> voters(String messageId);

  /// Polls of [conversationId] changing as they happen (vote counts, closing); resolves once subscribed. Realtime re-checks the read policy per subscriber. Votes themselves are never published, so who voted never travels live.
  Future<Result<Stream<PollChange>>> pollUpdates(String conversationId);
}

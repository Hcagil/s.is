import '../../../core/failure.dart';

/// Archiving boundary: whether the signed-in member has archived a chat. Archive state is per member and lives on the server, so it survives a reinstall and shows on every device. A repository never throws: a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatArchiveRepository {
  /// Archives [conversationId] for the caller (when [archived]) or brings it back. Idempotent: archiving an archived chat, or unarchiving one that is not, is [Ok]. DeniedFailure when the caller never belonged to the conversation.
  Future<Result<void>> setArchived(String conversationId, bool archived);
}

import '../../../core/failure.dart';

/// Deletion boundary: whether the signed-in member has deleted a chat. Delete state is per member and lives on the server, so it survives a reinstall and shows on every device. A repository never throws: a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatDeleteRepository {
  /// Hides [conversationId] from the caller's own list and old messages (delete for me). Nobody else sees a change. If someone writes again, the chat returns with only the new messages. DeniedFailure when the caller never belonged to it.
  Future<Result<void>> hideChat(String conversationId);

  /// Deletes the 1:1 [conversationId] for both people, with its photos. DeniedFailure when the caller is not a current member, or it is not a 1:1.
  Future<Result<void>> deleteDirectChat(String conversationId);
}

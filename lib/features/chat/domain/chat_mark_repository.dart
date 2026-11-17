import '../../../core/failure.dart';

/// Hand "mark as unread" boundary. A repository never throws: a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatMarkRepository {
  /// Marks [conversationId] unread for the signed-in member by hand (a flag kept on the server, so every phone shows it until the chat is opened again). Idempotent. DeniedFailure when the caller never belonged to the conversation.
  Future<Result<void>> markChatUnread(String conversationId);
}

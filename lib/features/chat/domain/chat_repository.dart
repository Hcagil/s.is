import '../../../core/failure.dart';
import 'conversation.dart';
import 'message.dart';

/// Chat boundary; the only way the app reaches conversations and messages.
///
/// Every call is subject to row-level security: the caller sees a conversation
/// only while it holds the active session and is a member. A repository never
/// throws — a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatRepository {
  /// Conversations the signed-in member belongs to, most recent first.
  Future<Result<List<Conversation>>> conversations();

  /// Messages in [conversationId], oldest first.
  Future<Result<List<Message>>> messages(String conversationId);

  /// Sends [body] to [conversationId]. The sender is the signed-in member;
  /// the server assigns the id and the timestamp.
  Future<Result<void>> send({
    required String conversationId,
    required String body,
  });

  /// Messages arriving in [conversationId] after subscription.
  ///
  /// Realtime delivery is a convenience, not an authority: the server re-checks
  /// the read policy for every subscriber.
  Stream<Message> incoming(String conversationId);

  /// The id of the 1:1 conversation with [otherUserId], creating it when it does
  /// not exist yet. Calling twice returns the same conversation.
  Future<Result<String>> startDirectConversation(String otherUserId);
}

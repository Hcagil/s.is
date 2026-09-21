import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import 'conversation.dart';
import 'message.dart';

/// Chat boundary; the only way the app reaches conversations and messages.
///
/// Every call is subject to row-level security: the caller sees a conversation
/// only while it holds the active session and is a member. A repository never
/// throws — a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatRepository {
  /// Everyone else who can sign in, so a first conversation can be started.
  /// Without this there is no way to reach [startDirectConversation], which
  /// needs another member's id.
  Future<Result<List<Member>>> members();

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
  /// The future completes only once the server has confirmed the subscription.
  /// Realtime delivers nothing that happened before that moment, so a caller
  /// must await this BEFORE its initial [messages] read — otherwise a message
  /// sent in between is missed by the subscription and already too late for
  /// the read.
  ///
  /// Realtime delivery is a convenience, not an authority: the server
  /// re-checks the read policy for every subscriber.
  Future<Stream<Message>> incoming(String conversationId);

  /// The id of the 1:1 conversation with [otherUserId], creating it when it does
  /// not exist yet. Calling twice returns the same conversation.
  Future<Result<String>> startDirectConversation(String otherUserId);
}

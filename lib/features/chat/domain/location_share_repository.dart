import '../../../core/failure.dart';
import 'shared_location.dart';

/// The boundary for sending a location as a message. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. The server checks the caller may post in the conversation.
abstract interface class LocationShareRepository {
  /// Stores the location message [messageId] (a client-generated id: a retry with the same id is harmless) in [conversationId]. DeniedFailure when the caller may not post there (not a member, the bot, the system chat); a network failure when offline (retryable); an invalid place is also a failure, never a crash.
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    SharedLocation location,
  );
}

import '../../../core/failure.dart';
import 'shared_contact.dart';

/// The boundary for sending a contact as a message. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. The server checks the caller may post in the conversation.
abstract interface class ContactShareRepository {
  /// Stores the contact message [messageId] (a client-generated id: a retry with the same id is harmless) in [conversationId]. DeniedFailure when the caller may not post there (not a member, the bot, the system chat); an invalid name or number is also a failure, never a crash.
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    SharedContact contact,
  );
}

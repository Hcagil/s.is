import '../../../core/failure.dart';
import 'message.dart';

/// The body every locked message row holds (the server CHECK requires exactly this text); the real text is only in the ciphertext.
const String lockedBodyPlaceholder = '🔒 Encrypted message';

/// Whether [body] is only the stand-in text of a locked message (never the real text): such a body is never forwarded or re-sent.
bool isLockedPlaceholder(String body) => body == lockedBodyPlaceholder;

/// Stores and edits locked (Olm-encrypted) text messages. The caller locks the text first; this only moves the ciphertext to the server.
abstract interface class EncryptedMessageRepository {
  /// Inserts the locked message [id] into [conversationId] as the signed-in member: body = [lockedBodyPlaceholder], [ciphertext] (base64) and [olmType] (0 pre-key, 1 normal). Returns the stored row (its body is the placeholder; the caller keeps its own plaintext). [replyTo] answers a message of that chat; [forwarded] marks a forward. A retried call with the same [id] after a lost answer reads the stored row back as Ok only when it is ours: same sender, same conversation and the SAME ciphertext (and reply target when given); any other row with that id is Err(DeniedFailure). Err(DeniedFailure) when the server refuses (not a member, a member without live keys, a bot or group chat); a retryable NetworkFailure when offline.
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String ciphertext,
    required int olmType,
    String? replyTo,
    bool forwarded = false,
  });

  /// Replaces the ciphertext of the member's own locked message [id] with a fresh one (RPC edit_message_encrypted). Returns the updated row (body still the placeholder, editedAt set). Err(DeniedFailure) when the server refuses: not theirs, not a locked row, deleted, forwarded, older than 6 hours, or a member has no live keys.
  Future<Result<Message>> edit({
    required String id,
    required String ciphertext,
    required int olmType,
  });
}

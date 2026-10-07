import '../../../core/failure.dart';
import 'group_event.dart';
import 'message.dart';

/// How many chats one member may pin. The database enforces the same number.
const maxPinnedChats = 5;

/// Pin boundary. Pinned chats are per member and live on the server (they survive a reinstall and show on every device); the pinned message is one per chat and shared by everyone in it. A repository never throws: a refusal arrives as [Err] with a typed [Failure].
abstract interface class ChatPinRepository {
  /// Pins [conversationId] for the caller (when [pinned]) or unpins it. Idempotent. PinLimitFailure when the caller already pinned 5 other chats; DeniedFailure when the caller never belonged to the conversation.
  Future<Result<void>> setChatPinned(String conversationId, bool pinned);

  /// Pins [messageId] in [conversationId]; null unpins. One pin per chat: a new pin replaces the old one. DeniedFailure when the caller may not pin here.
  Future<Result<void>> setPinnedMessage(
    String conversationId,
    String? messageId,
  );

  /// The pinned message as the caller may read it; Ok(null) when it is gone, deleted or outside what the caller may read.
  Future<Result<Message?>> pinnedMessage(
    String conversationId,
    String messageId,
  );

  /// The 'X pinned a message' lines (GroupEventKind.pinned), oldest first, for every member.
  Future<Result<List<GroupEvent>>> pinEvents(String conversationId);

  /// Sets whether every member may pin messages in the group (else admins only). Group admin only; DeniedFailure otherwise.
  Future<Result<void>> setMembersCanPin(String conversationId, bool allowed);
}

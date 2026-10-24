import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_settings_controller.dart';
import '../../notifications/domain/notification_settings.dart';
import '../domain/conversation.dart';
import '../domain/encrypted_message_repository.dart';
import '../domain/message.dart';
import 'chat_controllers.dart';

/// What the top card shows: the newest message of one other chat.
class MessageNoticeData {
  /// Creates a [MessageNoticeData] instance.
  const MessageNoticeData({
    required this.conversationId,
    required this.senderId,
    required this.preview,
    required this.locked,
    required this.textHidden,
    required this.count,
  });

  /// The chat the card opens when tapped.
  final String conversationId;

  /// Who sent the message.
  final String senderId;

  /// The stored one-line preview, same as the chat-list row holds.
  final String preview;

  /// The preview is only the locked placeholder (the phone cannot read it).
  final bool locked;

  /// The text must not be shown: locked, or the preview setting is not full.
  final bool textHidden;

  /// How many messages of this chat the card stands for.
  final int count;
}

/// The card now on screen, or null.
final messageNoticeProvider =
    NotifierProvider<MessageNoticeController, MessageNoticeData?>(
      MessageNoticeController.new,
    );

/// Holds the one card; a newer message from the same chat replaces it and
/// counts up.
class MessageNoticeController extends Notifier<MessageNoticeData?> {
  @override
  MessageNoticeData? build() => null;

  /// Shows a card for [message] when the member is inside another chat and the
  /// chat is not muted or archived.
  void consider(Conversation conversation, Message message) {
    final open = ref.read(openConversationProvider);
    if (open == null || open == message.conversationId) return;
    if (conversation.archived) return;
    // Mutes not loaded (loading or failed): no card, it could be muted.
    final mutes = ref.read(mutesProvider).value;
    if (mutes == null) return;
    final now = DateTime.now();
    if (activeMute(mutes, MuteKind.conversation, message.conversationId, now) !=
            null ||
        activeMute(mutes, MuteKind.person, message.senderId, now) != null) {
      return;
    }
    final raw = previewText(message);
    final locked = isLockedPlaceholder(raw);
    final settings = ref.read(notificationSettingsProvider).value;
    if (settings?.enabled == false) return;
    // Settings not loaded yet compares false: the text stays hidden.
    final full = settings?.preview == NotificationPreview.full;
    final old = state;
    final count = old != null && old.conversationId == message.conversationId
        ? old.count + 1
        : 1;
    state = MessageNoticeData(
      conversationId: message.conversationId,
      senderId: message.senderId,
      preview: raw,
      locked: locked,
      textHidden: locked || !full,
      count: count,
    );
  }

  /// Closes the card.
  void dismiss() => state = null;
}

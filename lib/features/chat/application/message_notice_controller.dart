import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/application/notification_settings_controller.dart';
import '../../notifications/application/push_controller.dart';
import '../../notifications/domain/notification_settings.dart';
import '../../notifications/domain/reaction_push.dart';
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
    this.reaction,
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

  /// Set for a reaction card: the card words it itself (null for a message).
  final ReactionLine? reaction;
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

  // Counts every card decision; a slow reaction push drops itself if it moved.
  int _gen = 0;

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
    _gen++;
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

  /// Shows a card for a reaction push when the member is inside another chat. The server already applied every rule (author, mute, on/off, preview); this adds none. Never on the chat list, never in the same chat.
  Future<void> onReactionPush(ReactionPush push) async {
    // Own reaction: the server never sends it; a second layer here.
    if (push.reactorId == push.userId || !_stillMine(push)) return;
    final gen = ++_gen;
    var line = (emoji: push.emoji, quote: push.quote, kind: push.quoteKind);
    if (push.ciphertext != null) {
      OpenedReaction? opened;
      try {
        // Opening must never hold the card for long: 3 s, then the generic text.
        opened = await ref
            .read(reactionPushOpenerProvider)(push)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        opened = null;
      }
      line = (emoji: opened?.emoji, quote: opened?.quote, kind: null);
      // The member may have moved, the session changed, or a newer card came while it was opened.
      if (gen != _gen || !_stillMine(push)) return;
    }
    state = MessageNoticeData(
      conversationId: push.conversationId,
      senderId: push.reactorId,
      preview: '',
      locked: false,
      textHidden: false,
      count: 1,
      reaction: line,
    );
  }

  /// The signed-in member is the push's addressee and is inside another chat.
  bool _stillMine(ReactionPush push) {
    final me = switch (ref.read(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    return me == push.userId && _otherChatOpen(push.conversationId);
  }

  bool _otherChatOpen(String conversationId) {
    final open = ref.read(openConversationProvider);
    return open != null && open != conversationId;
  }
}

/// Turns each foreground reaction push into a card. Watched once from the app shell.
final reactionCardProvider = Provider<void>((ref) {
  final sub = ref
      .watch(foregroundReactionProvider)
      .listen(
        (p) => unawaited(
          ref.read(messageNoticeProvider.notifier).onReactionPush(p),
        ),
      );
  ref.onDispose(() => unawaited(sub.cancel()));
});

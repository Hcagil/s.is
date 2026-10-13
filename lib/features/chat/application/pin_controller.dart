import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import 'chat_controllers.dart';
import 'group_controller.dart';

/// The pinned message the bar shows: read from the already loaded messages
/// first (instant), else fetched once. Any error means no bar.
final pinnedMessageProvider = FutureProvider.autoDispose
    .family<Message?, String>((ref, conversationId) async {
      ref.watch(currentUserIdProvider);
      final id = ref.watch(
        conversationListProvider.select(
          (s) => (s.value ?? const <Conversation>[])
              .where((c) => c.id == conversationId)
              .firstOrNull
              ?.pinnedMessageId,
        ),
      );
      if (id == null) return null;
      final loaded = ref.read(messagesProvider).value ?? const <Message>[];
      final here = loaded.where((m) => m.id == id).firstOrNull;
      if (here != null) return here.isDeleted ? null : here;
      final r = await ref
          .read(chatPinRepositoryProvider)
          .pinnedMessage(conversationId, id);
      return switch (r) {
        Ok(:final value) => value,
        Err() => null,
      };
    });

/// Whether the signed-in member may pin a message here: never in the SIS
/// system chat or a conversation they left; always in a 1:1; in a group when
/// "all members may pin" is on or they are a current admin.
final canPinProvider = Provider.autoDispose.family<bool, String>((
  ref,
  conversationId,
) {
  final me = ref.watch(currentUserIdProvider);
  final c = ref
      .watch(conversationListProvider)
      .value
      ?.where((c) => c.id == conversationId)
      .firstOrNull;
  if (me == null || c == null || c.isSystem || c.hasLeft) return false;
  if (!c.isGroup || c.settings.membersCanPin) return true;
  final roster = ref.watch(groupRosterProvider(conversationId)).value;
  return roster?.any((m) => m.member.userId == me && !m.hasLeft && m.isAdmin) ??
      false;
});

final pinControllerProvider = Provider<PinController>(PinController.new);

/// Pinning a message and the "who may pin" switch. Each change shows at
/// once and goes back if the server refuses.
class PinController {
  PinController(this.ref);

  final Ref ref;

  /// Makes [message] its conversation's pinned message (replacing any
  /// earlier one). On success the "X pinned a message" line is re-read.
  Future<Result<void>> pinMessage(Message message) async {
    final id = message.conversationId;
    final list = ref.read(conversationListProvider.notifier);
    final before = list.pinnedMessageOf(id);
    list.applyPinnedMessage(id, message.id);
    final result = await ref
        .read(chatPinRepositoryProvider)
        .setPinnedMessage(id, message.id);
    if (!ref.mounted) return result;
    if (result is Err) {
      list.applyPinnedMessage(id, before);
    } else {
      ref.invalidate(pinEventsProvider(id));
    }
    return result;
  }

  /// Clears [conversationId]'s pinned message. Leaves no line in the chat.
  Future<Result<void>> unpinMessage(String conversationId) async {
    final list = ref.read(conversationListProvider.notifier);
    final before = list.pinnedMessageOf(conversationId);
    list.applyPinnedMessage(conversationId, null);
    final result = await ref
        .read(chatPinRepositoryProvider)
        .setPinnedMessage(conversationId, null);
    if (result is Err && ref.mounted) {
      list.applyPinnedMessage(conversationId, before);
    }
    return result;
  }

  /// Sets who may pin messages in a group: everyone ([allowed]) or admins
  /// only. Admin-only on the server.
  Future<Result<void>> setMembersCanPin(
    String conversationId,
    bool allowed,
  ) async {
    final list = ref.read(conversationListProvider.notifier);
    final before = list.settingsOf(conversationId);
    if (before == null) return const Err(DeniedFailure());
    list.applySettings(conversationId, before.copyWith(membersCanPin: allowed));
    final result = await ref
        .read(chatPinRepositoryProvider)
        .setMembersCanPin(conversationId, allowed);
    if (result is Err && ref.mounted) {
      list.applySettings(
        conversationId,
        (list.settingsOf(conversationId) ?? before).copyWith(
          membersCanPin: before.membersCanPin,
        ),
      );
    }
    return result;
  }
}

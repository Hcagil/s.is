import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../notifications/application/notification_settings_controller.dart';
import '../../notifications/domain/notification_settings.dart';
import '../application/chat_controllers.dart';
import '../application/chat_delete_controller.dart';
import '../application/chat_selection_controller.dart';
import '../domain/conversation.dart';
import 'chat_delete_dialog.dart';
import 'chat_row_actions.dart';

/// The bar that replaces the home header while chats are selected: back,
/// how many, pin, mute, delete and a menu with archive and mark as read.
/// Every action ends the selection, as Telegram does.
class ChatSelectionBar extends ConsumerWidget implements PreferredSizeWidget {
  const ChatSelectionBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final ids = ref.watch(chatSelectionProvider);
    final all =
        ref.watch(conversationListProvider).value ?? const <Conversation>[];
    final chats = [
      for (final c in all)
        if (ids.contains(c.id)) c,
    ];
    final mutes = ref.watch(mutesProvider).value ?? const <Mute>[];
    final now = DateTime.now();
    final allMuted =
        chats.isNotEmpty &&
        chats.every(
          (c) => activeMute(mutes, MuteKind.conversation, c.id, now) != null,
        );
    final allPinned = chats.isNotEmpty && chats.every((c) => c.pinned);
    final selection = ref.read(chatSelectionProvider.notifier);
    final list = ref.read(conversationListProvider.notifier);
    final mutesNotifier = ref.read(mutesProvider.notifier);

    void notify(BuildContext context, Failure failure) {
      showSisNotice(
        context,
        failure is PinLimitFailure ? l.chatPinLimit : failure.message,
        isError: true,
      );
    }

    /// Runs [step] on each chat in turn; stops at the first refusal and
    /// says why. The selection ends either way.
    Future<void> each(
      BuildContext context,
      Future<Result<void>> Function(Conversation c) step,
    ) async {
      for (final c in chats) {
        final result = await step(c);
        if (result case Err(:final failure)) {
          if (context.mounted) notify(context, failure);
          break;
        }
      }
      selection.clear();
    }

    return AppBar(
      leading: BackButton(
        key: const ValueKey('selection-back'),
        onPressed: selection.clear,
      ),
      title: Text('${ids.length}', key: const ValueKey('selection-count')),
      actions: [
        IconButton(
          key: const ValueKey('selection-pin'),
          tooltip: allPinned ? l.chatMenuUnpin : l.chatSelPin,
          icon: Icon(allPinned ? Icons.push_pin : Icons.push_pin_outlined),
          onPressed: () =>
              each(context, (c) => list.setPinned(c.id, !allPinned)),
        ),
        Builder(
          builder: (button) => IconButton(
            key: const ValueKey('selection-mute'),
            tooltip: allMuted ? l.chatMenuUnmute : l.chatMenuMute,
            icon: Icon(
              allMuted
                  ? Icons.notifications_off_outlined
                  : Icons.notifications_outlined,
            ),
            onPressed: () async {
              if (allMuted) {
                return each(
                  button,
                  (c) => mutesNotifier.unmute(MuteKind.conversation, c.id),
                );
              }
              final box = button.findRenderObject() as RenderBox;
              final choice = await showChatMenuCard(
                button,
                anchor: box.localToGlobal(Offset.zero) & box.size,
                muted: false,
                pinned: false,
                canPin: false,
              );
              if (choice == null || choice == 'off' || !button.mounted) return;
              final length = MuteLength.values.byName(choice);
              await each(
                button,
                (c) => mutesNotifier.mute(MuteKind.conversation, c.id, length),
              );
            },
          ),
        ),
        if (!chats.any((c) => c.isSystem))
          IconButton(
            key: const ValueKey('selection-delete'),
            tooltip: l.chatDeleteAction,
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final also = await showDeleteChatsDialog(context, chats);
              if (also == null) return;
              ref
                  .read(chatDeleteProvider.notifier)
                  .start(chats, alsoForOthers: also);
            },
          ),
        PopupMenuButton<String>(
          key: const ValueKey('selection-more'),
          onSelected: (value) async {
            if (value == 'archive') {
              await each(context, (c) => list.setArchived(c.id, true));
            } else {
              for (final c in chats) {
                if (c.unread > 0) await list.markRead(c.id);
              }
              selection.clear();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              key: const ValueKey('selection-archive'),
              value: 'archive',
              child: Text(l.chatArchive),
            ),
            PopupMenuItem(
              key: const ValueKey('selection-read'),
              value: 'read',
              child: Text(l.chatSelMarkRead),
            ),
          ],
        ),
      ],
    );
  }
}

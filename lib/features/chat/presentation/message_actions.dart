import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import '../domain/group_member.dart';
import '../domain/message.dart';
import 'forward_page.dart';
import 'message_menu_card.dart';
import 'swipeable_message.dart';

enum _DeleteChoice { forMe, forEveryone }

/// Carries out [action] on [message]; reached from the swipe row and from
/// the tap menu. Which actions are offered for a message at all is
/// decided once, by `allowedMessageActions` / `menuMessageActions` in
/// `../domain/message.dart`; this function never re-checks that -- it
/// trusts the caller offered only an allowed action.
///
/// [canDeleteForEveryone] says whether the delete dialog also offers
/// "Delete for everyone" (the sender, or a group admin); "Delete for me"
/// is always there.
///
/// [anchor] (the bubble's global rect; [alignEnd] for your own messages) is
/// where the read-by card floats; [group] tells a group's card from a 1:1
/// chat's single "Read" line.
Future<bool> runMessageAction(
  BuildContext context,
  WidgetRef ref,
  Message message,
  MessageAction action, {
  bool canDeleteForEveryone = false,
  Rect? anchor,
  bool alignEnd = false,
  bool group = true,
}) async {
  switch (action) {
    case MessageAction.reply:
      ref.read(editingProvider.notifier).clear();
      ref.read(replyingToProvider.notifier).start(message);
      return true;
    case MessageAction.edit:
      ref.read(replyingToProvider.notifier).clear();
      ref.read(editingProvider.notifier).start(message);
      return false;
    case MessageAction.forward:
      await showForwardPage(context, ref, message);
      return false;
    case MessageAction.delete:
      break;
    case MessageAction.copy:
      await Clipboard.setData(ClipboardData(text: message.body));
      if (context.mounted) showSisNotice(context, 'Copied');
      return false;
  }
  if (!context.mounted) return false;

  final choice = await showDialog<_DeleteChoice>(
    context: context,
    builder: (dialog) {
      final colorScheme = Theme.of(dialog).colorScheme;
      return AlertDialog(
        title: const Text('Delete message?'),
        content: Text(
          canDeleteForEveryone
              ? 'Delete for me hides it on your devices only. Delete for '
                    'everyone removes it for everyone in this chat.'
              : 'Delete for me hides it on your devices only.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('delete-cancel'),
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('delete-for-me'),
            onPressed: () => Navigator.of(dialog).pop(_DeleteChoice.forMe),
            child: const Text('Delete for me'),
          ),
          if (canDeleteForEveryone)
            FilledButton(
              key: const ValueKey('delete-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
              onPressed: () =>
                  Navigator.of(dialog).pop(_DeleteChoice.forEveryone),
              child: const Text('Delete for everyone'),
            ),
        ],
      );
    },
  );

  if (choice == null || !context.mounted) return false;

  final notifier = ref.read(messagesProvider.notifier);
  final r = await (choice == _DeleteChoice.forMe
      ? notifier.hideForMe(message)
      : notifier.deleteForEveryone(message));
  if (r case Err(:final failure) when context.mounted) {
    showSisNotice(context, failure.message, isError: true);
  }
  return true;
}

/// Opens the tap menu for [message], a floating card next to [anchor] (the
/// tapped bubble's global rect; [alignEnd] for your own messages), and
/// carries out the chosen action. [photoViewer] limits it to reply, forward
/// and delete and hangs the card under the viewer's top-right menu button.
/// True when the action ended the interaction (see [runMessageAction]).
Future<bool> showMessageMenu(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  Rect? anchor,
  bool alignEnd = false,
  bool photoViewer = false,
  bool group = true,
}) async {
  final me = switch (ref.read(sessionControllerProvider).value) {
    Allowed(:final member) => member.userId,
    _ => null,
  };
  final roster =
      ref.read(groupRosterProvider(message.conversationId)).value ??
      const <GroupMember>[];
  final admin =
      me != null &&
      roster.any((m) => m.member.userId == me && m.isAdmin && !m.hasLeft);
  final actions = [
    for (final a in menuMessageActions(message, me: me, now: DateTime.now()))
      if (!photoViewer ||
          a == MessageAction.reply ||
          a == MessageAction.forward ||
          a == MessageAction.delete)
        a,
  ];
  if (actions.isEmpty) return false;
  final size = MediaQuery.sizeOf(context);
  final pad = MediaQuery.viewPaddingOf(context);
  final at =
      anchor ??
      (photoViewer
          ? Rect.fromLTRB(
              size.width - 56,
              pad.top,
              size.width,
              pad.top + kToolbarHeight,
            )
          : Rect.fromLTWH(size.width / 2, size.height / 2, 0, 0));
  final action = await showMenuCard<MessageAction>(
    context,
    anchor: at,
    alignEnd: alignEnd || photoViewer,
    highlightAnchor: !photoViewer && anchor != null,
    actions: [
      for (final a in actions)
        MenuCardAction(
          value: a,
          keyId: swipeActionKeyId(a),
          icon: swipeActionIcon(a),
          label: swipeActionLabel(a),
          destructive: a == MessageAction.delete,
        ),
    ],
  );
  if (action == null || !context.mounted) return false;
  return runMessageAction(
    context,
    ref,
    message,
    action,
    canDeleteForEveryone:
        me != null && message.canDeleteForEveryone(me, admin: admin),
    anchor: anchor,
    alignEnd: alignEnd,
    group: group,
  );
}

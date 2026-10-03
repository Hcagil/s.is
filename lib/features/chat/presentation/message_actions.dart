import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import '../../presence/domain/last_seen.dart';
import '../domain/group_member.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';
import 'forward_sheet.dart';
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
Future<bool> runMessageAction(
  BuildContext context,
  WidgetRef ref,
  Message message,
  MessageAction action, {
  bool canDeleteForEveryone = false,
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
      await showForwardSheet(context, ref, message);
      return false;
    case MessageAction.readBy:
      await _showReaders(context, ref, message);
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

/// Opens the tap menu for [message] and carries out the chosen action.
/// [photoViewer] limits it to reply, forward and delete (the full-screen
/// photo's menu). True when the action ended the interaction (see
/// [runMessageAction]).
Future<bool> showMessageMenu(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  bool photoViewer = false,
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
  final action = await showModalBottomSheet<MessageAction>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        key: const ValueKey('message-menu'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions)
            ListTile(
              key: ValueKey('menu-${swipeActionKeyId(a)}'),
              leading: Icon(
                swipeActionIcon(a),
                color: a == MessageAction.delete
                    ? Theme.of(sheet).colorScheme.error
                    : null,
              ),
              title: Text(swipeActionLabel(a)),
              onTap: () => Navigator.of(sheet).pop(a),
            ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;
  return runMessageAction(
    context,
    ref,
    message,
    action,
    canDeleteForEveryone:
        me != null && message.canDeleteForEveryone(me, admin: admin),
  );
}

/// Who has read [message], among the members who share read status with
/// you, and when.
Future<void> _showReaders(
  BuildContext context,
  WidgetRef ref,
  Message message,
) {
  final marks = ref.read(readMarksProvider).value ?? const <ReadMark>[];
  final names = {
    for (final gm
        in ref.read(groupRosterProvider(message.conversationId)).value ??
            const [])
      gm.member.userId: gm.member.displayName,
  };
  final readers = [
    for (final m in marks)
      if (m.hasRead(message.createdAt)) m,
  ];
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        key: const ValueKey('readers'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Read by',
              style: Theme.of(sheet).textTheme.titleMedium,
            ),
          ),
          if (readers.isEmpty)
            const ListTile(title: Text('Nobody yet'), enabled: false)
          else
            for (final m in readers)
              ListTile(
                key: ValueKey('reader-${m.userId}'),
                leading: const Icon(Icons.done_all),
                title: Text(names[m.userId] ?? 'Member'),
                subtitle: Text(lastSeenLabel(m.readAt!, DateTime.now())),
              ),
        ],
      ),
    ),
  );
}

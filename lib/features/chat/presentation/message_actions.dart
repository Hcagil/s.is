import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../application/chat_controllers.dart';
import '../../presence/domain/last_seen.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';
import 'forward_sheet.dart';

/// What a long press on a message offers: reply, forward, and -- for your
/// own message under 6 hours old -- delete for everyone. Nothing opens when
/// there is nothing to offer.
Future<void> showMessageActions(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  required String? me,
  bool group = false,
}) async {
  final canDelete =
      me != null && message.canDeleteForEveryone(me, DateTime.now());
  final canEdit = me != null && message.canEdit(me, DateTime.now());
  // Reply and forward need a stored message with something in it.
  final canShare = !message.isPending && !message.isDeleted;
  // In a group, who has read your message (where read status is shared).
  final canSeeReaders = group && me != null && message.isFrom(me) && canShare;
  if (!canDelete && !canShare && !canEdit) return;

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canSeeReaders)
            ListTile(
              key: const ValueKey('action-read-by'),
              leading: const Icon(Icons.done_all),
              title: const Text('Read by'),
              onTap: () => Navigator.of(sheet).pop('read-by'),
            ),
          if (canShare) ...[
            ListTile(
              key: const ValueKey('action-reply'),
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () => Navigator.of(sheet).pop('reply'),
            ),
            ListTile(
              key: const ValueKey('action-forward'),
              leading: const Icon(Icons.shortcut),
              title: const Text('Forward'),
              onTap: () => Navigator.of(sheet).pop('forward'),
            ),
          ],
          if (canEdit)
            ListTile(
              key: const ValueKey('action-edit'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.of(sheet).pop('edit'),
            ),
          if (canDelete)
            ListTile(
              key: const ValueKey('action-delete'),
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(sheet).colorScheme.error,
              ),
              title: Text(
                'Delete for everyone',
                style: TextStyle(color: Theme.of(sheet).colorScheme.error),
              ),
              onTap: () => Navigator.of(sheet).pop('delete'),
            ),
        ],
      ),
    ),
  );

  if (!context.mounted) return;
  switch (action) {
    case 'reply':
      ref.read(editingProvider.notifier).clear();
      ref.read(replyingToProvider.notifier).start(message);
      return;
    case 'edit':
      ref.read(replyingToProvider.notifier).clear();
      ref.read(editingProvider.notifier).start(message);
      return;
    case 'forward':
      await showForwardSheet(context, ref, message);
      return;
    case 'read-by':
      await _showReaders(context, ref, message);
      return;
    case 'delete':
      break;
    default:
      return;
  }
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      final colorScheme = Theme.of(dialog).colorScheme;
      return AlertDialog(
        title: const Text('Delete for everyone?'),
        content: const Text(
          'The message is removed for everyone in this chat.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('delete-cancel'),
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );

  if (confirmed != true || !context.mounted) return;

  final r = await ref
      .read(messagesProvider.notifier)
      .deleteForEveryone(message);
  if (r case Err(:final failure) when context.mounted) {
    showSisNotice(context, failure.message, isError: true);
  }
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
    for (final m in ref.read(membersProvider).value ?? const [])
      m.userId: m.displayName,
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

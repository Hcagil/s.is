import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../application/chat_controllers.dart';
import '../../presence/domain/last_seen.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';
import 'forward_sheet.dart';

/// Carries out [action] on [message] -- the same behaviour the long-press
/// menu used to run, now reached by swiping instead. Which actions are
/// offered for a message at all is decided once, by
/// `allowedMessageActions` in `../domain/message.dart`; this function never
/// re-checks that -- it trusts the caller offered only an allowed action.
Future<void> runMessageAction(
  BuildContext context,
  WidgetRef ref,
  Message message,
  MessageAction action,
) async {
  switch (action) {
    case MessageAction.reply:
      ref.read(editingProvider.notifier).clear();
      ref.read(replyingToProvider.notifier).start(message);
      return;
    case MessageAction.edit:
      ref.read(replyingToProvider.notifier).clear();
      ref.read(editingProvider.notifier).start(message);
      return;
    case MessageAction.forward:
      await showForwardSheet(context, ref, message);
      return;
    case MessageAction.readBy:
      await _showReaders(context, ref, message);
      return;
    case MessageAction.delete:
      break;
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
    for (final m in ref.read(yourPeopleProvider).value ?? const [])
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

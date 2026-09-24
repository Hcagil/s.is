import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';

/// What a long press on a message offers. Nothing opens when there is
/// nothing to offer.
Future<void> showMessageActions(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  required String? me,
}) async {
  final canDelete =
      me != null && message.canDeleteForEveryone(me, DateTime.now());
  if (!canDelete) return;

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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

  if (action != 'delete' || !context.mounted) return;

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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(failure.message)));
  }
}

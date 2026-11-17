import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// Asks [title] / [body]; returns true only when the person presses the red [action] button.
Future<bool> showInviteConfirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final l = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('invite-confirm'),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: const ValueKey('invite-confirm-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l.groupLeaveCancel),
        ),
        TextButton(
          key: const ValueKey('invite-confirm-ok'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

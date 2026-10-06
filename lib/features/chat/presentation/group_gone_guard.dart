import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/group_controller.dart';

/// When an admin deletes the group this screen belongs to, this sends the
/// member back to the chat list with one plain line instead of leaving them
/// on a dead screen. Call from build(), like ref.listen. Only a real deletion
/// counts (see [deletedGroupsProvider]): a chat that is merely missing from
/// the list (a session change, a left group) is not "gone".
void listenGroupGone(
  BuildContext context,
  WidgetRef ref,
  String? conversationId,
) {
  if (conversationId == null) return;
  ref.listen(deletedGroupsProvider, (previous, next) {
    if (!next.contains(conversationId) ||
        (previous?.contains(conversationId) ?? false)) {
      return;
    }
    if (!context.mounted) return;
    if (ref.read(deletedGroupsProvider.notifier).claimNotice(conversationId)) {
      showSisNotice(context, AppLocalizations.of(context).groupDeletedNotice);
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  });
}

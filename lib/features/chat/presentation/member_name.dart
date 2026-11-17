import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../auth/application/deleted_users_controller.dart';
import '../domain/conversation.dart';

/// A member's name for display. The data layer returns an empty name when a
/// profile is unknown; this is where it becomes the localised "Member".
String nameOrMember(AppLocalizations l, String name) =>
    name.isEmpty ? l.commonMember : name;

/// A person's name for display: [name]; when it is unknown, "Deleted account" if the server said that account is gone, else "Member".
String nameOrDeleted(
  AppLocalizations l,
  String name,
  String id,
  Set<String> deleted,
) => name.isNotEmpty
    ? name
    : deleted.contains(id)
    ? l.deletedAccountName
    : l.commonMember;

/// Asks the server (once per id, see [DeletedUsersController]) which of [ids] are deleted accounts. Call from build with the ids that have no name.
void askDeletedAccounts(WidgetRef ref, Iterable<String> ids) {
  final asked = ids.toList();
  if (asked.isEmpty) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (ref.context.mounted) {
      ref.read(deletedUsersControllerProvider.notifier).check(asked);
    }
  });
}

/// A conversation's name for display; an unknown 1:1 partner shows "Member", or "Deleted account" when its id is in [deleted].
String conversationLabel(
  AppLocalizations l,
  Conversation c, {
  Set<String> deleted = const {},
}) => c.staffKey != null || c.isAdminChat
    ? l.staffChatTitleFallback
    : c.label.isEmpty && c.other != null && deleted.contains(c.other!.userId)
    ? l.deletedAccountName
    : nameOrMember(l, c.label);

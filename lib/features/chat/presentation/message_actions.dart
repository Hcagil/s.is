import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/sheen.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import '../domain/group_member.dart';
import '../domain/message.dart';
import 'forward_page.dart';
import 'message_menu_card.dart';
import 'swipeable_message.dart';

/// Carries out [action] on [message]; reached from the swipe-reply, the
/// screen-reader custom actions and the long-press card. Which actions are
/// offered for a message at all is decided once, by `allowedMessageActions` /
/// `menuMessageActions` in `../domain/message.dart`; this function never
/// re-checks that -- it trusts the caller offered only an allowed action.
/// The two delete actions ask for a confirmation card first; pin is greyed
/// (not built yet) and does nothing.
Future<bool> runMessageAction(
  BuildContext context,
  WidgetRef ref,
  Message message,
  MessageAction action,
) async {
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
    case MessageAction.copy:
      await Clipboard.setData(ClipboardData(text: message.body));
      if (context.mounted) showSisNotice(context, 'Copied');
      return false;
    case MessageAction.pin:
      return false;
    case MessageAction.deleteForMe:
    case MessageAction.deleteForEveryone:
      break;
  }
  if (!context.mounted) return false;

  final forEveryone = action == MessageAction.deleteForEveryone;
  final confirmed = await _confirmDelete(context, forEveryone: forEveryone);
  if (confirmed != true || !context.mounted) return false;

  final notifier = ref.read(messagesProvider.notifier);
  final r = await (forEveryone
      ? notifier.deleteForEveryone(message)
      : notifier.hideForMe(message));
  if (r case Err(:final failure) when context.mounted) {
    showSisNotice(context, failure.message, isError: true);
  }
  return true;
}

/// The floating confirmation for a delete: true to go ahead, false or null
/// to leave the message alone.
Future<bool?> _confirmDelete(
  BuildContext context, {
  required bool forEveryone,
}) {
  final anchor = Rect.fromCenter(
    center: MediaQuery.sizeOf(context).center(Offset.zero),
    width: 0,
    height: 0,
  );
  return showFloatingCard<bool>(
    context,
    anchor: anchor,
    highlightAnchor: false,
    cardKey: const ValueKey('delete-card'),
    child: Builder(
      builder: (card) {
        final l = AppLocalizations.of(card);
        final scheme = Theme.of(card).colorScheme;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.messageDeleteTitle,
                style: Theme.of(card).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                forEveryone
                    ? l.messageDeleteForEveryoneBody
                    : l.messageDeleteForMeBody,
              ),
              const SizedBox(height: 16),
              Sheen(
                child: FilledButton(
                  key: const ValueKey('delete-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: () => Navigator.of(card).pop(true),
                  child: Text(
                    forEveryone
                        ? l.messageActionDeleteForEveryone
                        : l.messageActionDeleteForMe,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('delete-cancel'),
                onPressed: () => Navigator.of(card).pop(false),
                child: Text(l.messageDeleteCancel),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Opens the long-press action card for [message], a floating card next to
/// [anchor] (the pressed bubble's global rect, kept lit; [alignEnd] for your
/// own messages), and carries out the chosen action. [photoViewer] limits it
/// to reply, forward and the two delete rows and hangs the card under the
/// viewer's top-right menu button. True when the action ended the interaction
/// (see [runMessageAction]).
Future<bool> showMessageMenu(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  Rect? anchor,
  bool alignEnd = false,
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
    for (final a in menuMessageActions(
      message,
      me: me,
      now: DateTime.now(),
      admin: admin,
    ))
      if (!photoViewer ||
          a == MessageAction.reply ||
          a == MessageAction.forward ||
          a == MessageAction.deleteForMe ||
          a == MessageAction.deleteForEveryone)
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
          label: swipeActionLabel(AppLocalizations.of(context), a),
          destructive:
              a == MessageAction.deleteForMe ||
              a == MessageAction.deleteForEveryone,
          greyName: a == MessageAction.pin ? 'pin' : null,
        ),
    ],
  );
  if (action == null || !context.mounted) return false;
  return runMessageAction(context, ref, message, action);
}

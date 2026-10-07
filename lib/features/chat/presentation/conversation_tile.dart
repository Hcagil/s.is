import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/message.dart';
import '../../presence/application/presence_controllers.dart';
import '../application/chat_controllers.dart';
import '../domain/conversation.dart';
import 'member_name.dart';
import 'message_screen.dart';
import 'person_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../notifications/application/notification_settings_controller.dart';
import '../../notifications/domain/notification_settings.dart';
import 'chat_row_actions.dart';

class ConversationTile extends ConsumerWidget {
  const ConversationTile(
    this.conversation, {
    super.key,
    this.inArchive = false,
  });

  final Conversation conversation;

  /// True on the Archived screen: the row swipes to UNarchive, and shows no unread pill (an archived chat is silent; new messages only make its preview bold).
  final bool inArchive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    // Whose messages are "mine" comes from the session, as on the message
    // screen.
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    final scheme = Theme.of(context).colorScheme;
    final unread = conversation.unread > 0;
    final showPill = unread && !inArchive;
    final muted = ref.watch(
      mutesProvider.select(
        (m) =>
            activeMute(
              m.value ?? const <Mute>[],
              MuteKind.conversation,
              conversation.id,
              DateTime.now(),
            ) !=
            null,
      ),
    );
    // A group left or been removed from: read-only history, nothing new can
    // ever arrive, so the tile is greyed like a departed member's name
    // elsewhere in that same group.
    final left = conversation.hasLeft;
    // A group row names its last sender, in their colour in that group.
    final voice =
        conversation.isGroup &&
            !conversation.isSystem &&
            conversation.lastSenderId != me
        ? conversation.senders[conversation.lastSenderId]
        : null;
    final previewStyle = unread
        ? TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600)
        : left
        ? TextStyle(color: scheme.onSurfaceVariant)
        : null;
    return ChatRowSwipe(
      id: conversation.id,
      label: inArchive ? l.chatUnarchive : l.chatArchive,
      onCommit: () => _toggleArchive(context, ref),
      child: ListTile(
        key: ValueKey('conversation-${conversation.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        leading: PersonAvatar(
          label: conversationLabel(l, conversation),
          // A person keeps one tint everywhere; a group has its own.
          seed: conversation.other?.userId ?? conversation.id,
          online:
              conversation.other != null &&
              ref
                  .watch(onlineMembersProvider)
                  .contains(conversation.other!.userId),
          dotKey: ValueKey('online-${conversation.id}'),
          avatarPath: conversation.avatarPath ?? conversation.other?.avatarPath,
        ),
        title: Text(
          conversationLabel(l, conversation),
          key: left ? ValueKey('left-${conversation.id}') : null,
          style: TextStyle(
            fontWeight: unread ? FontWeight.w800 : FontWeight.w700,
            color: left ? scheme.onSurfaceVariant : null,
          ),
        ),
        subtitle: conversation.lastMessage == null
            ? Text(l.listNoMessages)
            : voice != null
            ? Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: nameOrMember(l, voice.name),
                      style: TextStyle(
                        color: groupColor(context, voice.slot),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: ': ${conversation.lastMessage}'),
                  ],
                ),
                key: ValueKey('preview-${conversation.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: previewStyle,
              )
            : Text(
                conversation.lastSenderId != null &&
                        conversation.lastSenderId == me
                    ? l.listYouPrefix(conversation.lastMessage!)
                    : conversation.lastMessage!,
                key: ValueKey('preview-${conversation.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: previewStyle,
              ),
        trailing: conversation.lastMessageAt == null && !muted && !showPill
            ? null
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (conversation.lastMessageAt != null)
                    Text(
                      previewTime(conversation.lastMessageAt!, DateTime.now()),
                      key: ValueKey('preview-time-${conversation.id}'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: unread ? scheme.primary : null,
                        fontWeight: unread ? FontWeight.w700 : null,
                      ),
                    ),
                  if (muted || showPill) ...[
                    if (conversation.lastMessageAt != null)
                      const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (muted)
                          Icon(
                            Icons.notifications_off_outlined,
                            key: ValueKey('muted-${conversation.id}'),
                            size: 14,
                            color: scheme.onSurfaceVariant,
                            semanticLabel: AppLocalizations.of(context)
                                .chatMutedLabel,
                          ),
                        if (muted && showPill) const SizedBox(width: 4),
                        if (showPill)
                          Container(
                            key: ValueKey('unread-${conversation.id}'),
                            // No `alignment`: an aligned Container grows to all the
                            // width it is offered, and a ListTile trailing is offered
                            // the whole row. Sized by its text, at least round.
                            constraints: const BoxConstraints(minWidth: 20),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: muted ? scheme.onSurfaceVariant : null,
                              gradient: muted
                                  ? null
                                  : LinearGradient(
                                      colors: [
                                        scheme.primary.withValues(alpha: 0.5),
                                        scheme.primary.withValues(alpha: 0.8),
                                        scheme.primary.withValues(alpha: 0.5),
                                      ],
                                    ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              conversation.unread > 99
                                  ? '99+'
                                  : '${conversation.unread}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: scheme.onPrimary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
        onLongPress: () => _openMenu(context, ref, muted),
        onTap: () => openConversation(
          context,
          ref,
          conversation.id,
          title: conversationLabel(l, conversation),
          otherUserId: conversation.other?.userId,
          group: conversation.isGroup,
        ),
      ),
    );
  }

  /// The swipe was released past its line: archive this chat (or bring it
  /// back, on the Archived screen). The list changes at once; a refusal puts
  /// the chat back and says why. The row is gone by then, so the notice
  /// comes from the screen's Scaffold, which stays.
  Future<void> _toggleArchive(BuildContext context, WidgetRef ref) async {
    final host = Scaffold.of(context).context;
    final result = await ref
        .read(conversationListProvider.notifier)
        .setArchived(conversation.id, !inArchive);
    if (result case Err(:final failure) when host.mounted) {
      showSisNotice(host, failure.message, isError: true);
    }
  }

  Future<void> _openMenu(
    BuildContext context,
    WidgetRef ref,
    bool muted,
  ) async {
    final box = context.findRenderObject() as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final choice = await showChatMenuCard(
      context,
      anchor: anchor,
      muted: muted,
    );
    if (choice == null || !context.mounted) return;
    final notifier = ref.read(mutesProvider.notifier);
    final result = choice == 'off'
        ? await notifier.unmute(MuteKind.conversation, conversation.id)
        : await notifier.mute(
            MuteKind.conversation,
            conversation.id,
            MuteLength.values.byName(choice),
          );
    if (result case Err(:final failure) when context.mounted) {
      showSisNotice(context, failure.message, isError: true);
    }
  }
}

/// A hairline that fades out at both ends.
class FadeDivider extends StatelessWidget {
  const FadeDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).colorScheme.outlineVariant;
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [line.withValues(alpha: 0), line, line.withValues(alpha: 0)],
        ),
      ),
    );
  }
}

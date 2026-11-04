import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../notifications/domain/reaction_push.dart';
import '../application/chat_controllers.dart';
import '../application/message_notice_controller.dart';
import 'conversation_tile.dart';
import 'lock_glyph.dart';
import 'member_name.dart';
import 'person_avatar.dart';

/// The top card for a message from another chat: avatar, chat name, one line
/// of text (or a lock and "New message"), and a "+n" chip for several.
class MessageNoticeCard extends ConsumerWidget {
  /// Creates the card for [data]; [onTap] opens the chat.
  const MessageNoticeCard({super.key, required this.data, this.onTap});

  /// What the card shows.
  final MessageNoticeData data;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    final c = ref
        .watch(conversationListProvider)
        .value
        ?.where((conversation) => conversation.id == data.conversationId)
        .firstOrNull;
    // Chat data unavailable: show nothing.
    if (c == null) return const SizedBox.shrink();
    final title = conversationLabel(l, c);
    final reaction = data.reaction;
    final text = reaction != null
        ? reactionCardText(l, reaction)
        : data.textHidden
        ? l.noticeNewMessage
        : chatPreviewLine(l, data.preview);
    final voice = c.isGroup && !c.isSystem && !data.textHidden
        ? c.senders[data.senderId]
        : null;
    final body = voice == null ? text : '${nameOrMember(l, voice.name)}: $text';
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Semantics(
          liveRegion: true,
          label: '$title: $body',
          excludeSemantics: true,
          onTap: onTap,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              key: const ValueKey('message-notice'),
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: t.surfaceHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.line),
                boxShadow: [
                  BoxShadow(
                    color: Color(
                      Theme.of(context).brightness == Brightness.dark
                          ? 0x8C000000
                          : 0x29000000,
                    ),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  PersonAvatar(
                    label: title,
                    seed: c.other?.userId ?? c.id,
                    radius: 20,
                    avatarPath: c.avatarPath ?? c.other?.avatarPath,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        // A reaction line goes here later (separate task).
                        Row(
                          children: [
                            if (data.locked) ...[
                              LockGlyph(color: t.muted),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                body,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.muted, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (data.count > 1) ...[
                    const SizedBox(width: 8),
                    Container(
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: t.brand,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '+${data.count}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card line for a reaction, in the order the phones use: no emoji is the generic text; a quote wins (even for media); else the media kind; else "your message".
String reactionCardText(AppLocalizations l, ReactionLine r) {
  final e = r.emoji;
  if (e == null || e.isEmpty) return l.noticeReactionGeneric;
  final q = r.quote;
  if (q != null && q.isNotEmpty) return l.noticeReactionToQuote(e, q);
  return switch (r.kind) {
    'photo' => l.noticeReactionToPhoto(e),
    'video' => l.noticeReactionToVideo(e),
    'sticker' => l.noticeReactionToSticker(e),
    'voice' => l.noticeReactionToVoice(e),
    'file' => l.noticeReactionToFile(e),
    _ => l.noticeReactionToMessage(e),
  };
}

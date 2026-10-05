part of 'message_screen.dart';

class _Bubble extends StatelessWidget {
  const _Bubble(
    this.message, {
    super.key,
    required this.mine,
    required this.unread,
    this.sender,
    this.senderLeft = false,
    this.senderSlot,
    this.quoted,
    this.quotedName,
    this.highlightQuery,
    this.isCurrentHit = false,
  });

  final Message message;
  final bool mine;

  /// True for an own message no other member has read yet (or still
  /// sending). Shown as a thin yellow edge, never as a dimmed bubble.
  final bool unread;

  /// The message this one answers, when it is loaded here, and who wrote it.
  final Message? quoted;
  final String? quotedName;

  /// The sender's name, shown above the first bubble of their run in a group.
  final String? sender;

  /// True when [sender] has left or been removed from the group -- their
  /// name is greyed rather than tinted, everywhere it is still shown.
  final bool senderLeft;

  /// [sender]'s colour slot in this group; null (not known yet) falls back to
  /// the person's own tint.
  final int? senderSlot;

  /// The active in-chat search query, if any: every match in [message]'s
  /// body is highlighted.
  final String? highlightQuery;

  /// This bubble is the search's current hit -- shown with a purple edge,
  /// on either side, distinct from the amber "unread" edge (which stays on
  /// a merely-unread bubble that is not the current hit).
  final bool isCurrentHit;

  // The bubble's own outer cap and the two insets that eat into it: 12 px
  // padding, plus -- for a "mine" bubble, or the current search hit -- a
  // 1.5 px border that is always laid out (even transparent, when read).
  // _BodyWithTime measures its fits-inline decision against [_contentWidth],
  // not a copy of these numbers, so the two cannot drift apart.
  static const _maxWidth = 320.0;
  static const _hPad = 12.0;
  static const _borderWidth = 1.5;

  bool get _hasBorder => mine || isCurrentHit;

  double get _contentWidth =>
      _maxWidth - 2 * _hPad - (_hasBorder ? 2 * _borderWidth : 0);

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    // Square-ish corner on the sender's side marks whose bubble it is.
    const r = Radius.circular(11);
    const tail = Radius.circular(4);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey('message-${message.id}'),
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? null : brand.theirs,
          gradient: mine ? brand.gradient : null,
          borderRadius: BorderRadius.only(
            topLeft: r,
            topRight: r,
            bottomLeft: mine ? r : tail,
            bottomRight: mine ? tail : r,
          ),
          border: _hasBorder
              ? Border.all(
                  width: _borderWidth,
                  // The current hit is always the app's purple, distinct
                  // from the amber "unread" edge -- even on a bubble that
                  // is both unread and the current hit. A still-sending
                  // text message shows a clock mark instead of this edge.
                  color: isCurrentHit
                      ? Theme.of(context).colorScheme.primary
                      : (unread && !message.sending
                            ? brand.unreadEdge
                            : Colors.transparent),
                )
              : null,
        ),
        // Without this, a non-stretched Column still hands each child a
        // *loose* constraint up to the Container's own maxWidth (320): any
        // child that fills the space it is offered -- Align without a
        // widthFactor does, below -- reports back a width of 320, so the
        // Column (sized to its widest child) is 320 wide even for one short
        // word. IntrinsicWidth measures the content first and passes that
        // tight width down instead, so Align has nothing left to expand
        // into.
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.deletion == MessageDeletion.placeholder)
                Row(
                  key: ValueKey('deleted-${message.id}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.block,
                      size: 16,
                      color: mine
                          ? Colors.white70
                          : brand.text.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        message.deletedByAdmin
                            ? 'Deleted by an admin'
                            : 'This message was deleted',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: mine
                              ? Colors.white70
                              : brand.text.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
              if (message.forwarded)
                Padding(
                  key: ValueKey('forwarded-${message.id}'),
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.shortcut,
                        size: 14,
                        color: mine
                            ? Colors.white70
                            : brand.text.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Forwarded',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: mine
                                ? Colors.white70
                                : brand.text.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (message.replyTo != null && !message.isDeleted)
                GestureDetector(
                  // A tap on a quote is its own (it opens nothing); it must not reach the bubble's menu tap.
                  onTap: () {},
                  child: Container(
                    key: ValueKey('quote-${message.id}'),
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    decoration: BoxDecoration(
                      color: (mine ? Colors.white : brand.text).withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(6),
                      border: Border(
                        left: BorderSide(
                          color: mine
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (quotedName != null)
                          Text(
                            quotedName!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: mine
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        Text(
                          quoteText(quoted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: mine ? Colors.white : brand.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (sender != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    sender!,
                    key: ValueKey('sender-${message.id}'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: senderLeft
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : senderSlot != null
                          ? groupColor(context, senderSlot!)
                          : personTint(context, message.senderId, ink: true),
                    ),
                  ),
                ),
              if (message.hasAttachment) _Attachment(message),
              // An image may be sent without a caption, so an empty body must
              // render nothing at all rather than an empty line. A deleted
              // message never shows a time, but (defensively) may still carry
              // a body, so the two conditions stay independent below.
              if (message.body.isNotEmpty && !message.isDeleted)
                _BodyWithTime(
                  message: message,
                  bodyStyle: TextStyle(
                    fontSize: isBigEmoji(message.body) ? 40 : 15,
                    color: mine ? Colors.white : brand.text,
                  ),
                  linkColor: mine
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary,
                  maxContentWidth: _contentWidth,
                  topPadding: message.hasAttachment ? 8 : 0,
                  timeText: message.isEdited
                      ? 'edited ${clockTime(message.createdAt)}'
                      : clockTime(message.createdAt),
                  timeStyle: TextStyle(
                    fontSize: 11,
                    color: (mine ? Colors.white : brand.text).withValues(
                      alpha: 0.6,
                    ),
                  ),
                  highlightQuery: highlightQuery,
                )
              else ...[
                if (message.body.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: message.hasAttachment ? 8 : 0,
                    ),
                    child: _LinkedText(
                      message.body,
                      key: ValueKey('body-${message.id}'),
                      style: TextStyle(
                        fontSize: 15,
                        color: mine ? Colors.white : brand.text,
                      ),
                      highlightQuery: highlightQuery,
                      linkColor: mine
                          ? Colors.white
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                if (!message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        message.isEdited
                            ? 'edited ${clockTime(message.createdAt)}'
                            : clockTime(message.createdAt),
                        key: ValueKey('time-${message.id}'),
                        style: TextStyle(
                          fontSize: 11,
                          color: (mine ? Colors.white : brand.text).withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

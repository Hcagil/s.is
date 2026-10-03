import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../domain/message.dart';

/// How far right (logical px) a bubble must be dragged before release
/// commits to opening its action row; also the offset it rests at once
/// open. Chosen well past an accidental scroll's horizontal jitter, well
/// short of dragging the bubble off screen.
const double swipeActionThreshold = 64.0;

/// A little extra travel past [swipeActionThreshold] the finger may drag to,
/// purely for feel -- release always settles back to 0.
const double _swipeOverdrag = 24.0;

/// The icon shown on [action]'s box, reused by the swipe row and (as a
/// screen-reader custom action) by each swipeable bubble.
IconData swipeActionIcon(MessageAction action) => switch (action) {
  MessageAction.readBy => Icons.done_all,
  MessageAction.reply => Icons.reply,
  MessageAction.forward => Icons.shortcut,
  MessageAction.edit => Icons.edit_outlined,
  MessageAction.delete => Icons.delete_outline,
  MessageAction.copy => Icons.copy_outlined,
};

/// The short label on [action]'s box.
String swipeActionLabel(MessageAction action) => switch (action) {
  MessageAction.readBy => 'Read by',
  MessageAction.reply => 'Reply',
  MessageAction.forward => 'Forward',
  MessageAction.edit => 'Edit',
  MessageAction.delete => 'Delete',
  MessageAction.copy => 'Copy',
};

/// The fuller wording a screen reader announces for [action], as a custom
/// semantics action on the bubble itself.
String swipeActionSemanticLabel(MessageAction action) =>
    action == MessageAction.delete
    ? 'Delete for everyone'
    : swipeActionLabel(action);

/// The `action-<id>` suffix [action]'s box (and any test) is keyed by.
String swipeActionKeyId(MessageAction action) => switch (action) {
  MessageAction.readBy => 'read-by',
  MessageAction.reply => 'reply',
  MessageAction.forward => 'forward',
  MessageAction.edit => 'edit',
  MessageAction.delete => 'delete',
  MessageAction.copy => 'copy',
};

/// Wraps a message bubble so it can be dragged right to reveal [actions]: a
/// row of separate SIS boxes above it, one per allowed action. Skips the
/// gesture entirely when [actions] is empty -- a deleted, vanished or
/// still-sending message has nothing to offer, so it does not swipe.
///
/// [openId] holds the id of whichever message currently has its row open --
/// at most one at a time, coordinated across every bubble in the list. This
/// widget listens to it directly (not through its parent's build), and every
/// drag update only calls [State.setState] on itself, so dragging one bubble
/// never rebuilds the message list.
class SwipeableMessage extends StatefulWidget {
  const SwipeableMessage({
    super.key,
    required this.messageId,
    required this.mine,
    required this.actions,
    required this.openId,
    required this.onOpenChanged,
    required this.onAction,
    required this.child,
    this.onTap,
  });

  /// The message this bubble belongs to.
  final String messageId;

  /// True for your own message: the action row aligns to the same side as
  /// the bubble does.
  final bool mine;

  /// The actions this message allows right now, in display order. Empty
  /// disables the gesture entirely.
  final List<MessageAction> actions;

  /// The id of the message whose row is currently open, or null.
  final ValueListenable<String?> openId;

  /// Called with true when this bubble's row commits open.
  ///
  /// It is never called with false from this widget; closing happens only
  /// via the parent moving [openId] away, which this widget picks up itself
  /// through [openId]'s listener, not through this callback.
  final ValueChanged<bool> onOpenChanged;

  /// Called when a box in this bubble's row (or its matching screen-reader
  /// custom action) is chosen.
  final ValueChanged<MessageAction> onAction;

  /// Called on a tap on the bubble (photo, link and quote taps win over it);
  /// works even when [actions] is empty. Null: no tap.
  final VoidCallback? onTap;

  final Widget child;

  @override
  State<SwipeableMessage> createState() => _SwipeableMessageState();
}

class _SwipeableMessageState extends State<SwipeableMessage> {
  double _dragDx = 0;
  bool _dragging = false;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    widget.openId.addListener(_onOpenIdChanged);
  }

  @override
  void didUpdateWidget(covariant SwipeableMessage old) {
    super.didUpdateWidget(old);
    if (old.openId != widget.openId) {
      old.openId.removeListener(_onOpenIdChanged);
      widget.openId.addListener(_onOpenIdChanged);
    }
  }

  @override
  void dispose() {
    widget.openId.removeListener(_onOpenIdChanged);
    super.dispose();
  }

  void _onOpenIdChanged() {
    final shouldBeOpen = widget.openId.value == widget.messageId;
    if (shouldBeOpen != _open && !_dragging) {
      setState(() {
        _open = shouldBeOpen;
      });
    }
  }

  void _onDragStart(DragStartDetails _) {
    _dragging = true;
    _dragDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragDx = (_dragDx + details.delta.dx).clamp(
        0.0,
        swipeActionThreshold + _swipeOverdrag,
      );
    });
  }

  void _finishDrag() {
    final willOpen = _dragDx >= swipeActionThreshold;
    final wasOpen = _open;
    setState(() {
      _dragging = false;
      _open = _open || willOpen;
      _dragDx = 0;
    });
    if (willOpen && !wasOpen) HapticFeedback.selectionClick();
    if (willOpen && !wasOpen) widget.onOpenChanged(true);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) {
      return widget.onTap == null
          ? widget.child
          : GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTap: widget.onTap,
              child: widget.child,
            );
    }
    final offset = _dragging ? _dragDx : 0.0;
    return Semantics(
      customSemanticsActions: {
        for (final action in widget.actions)
          CustomSemanticsAction(label: swipeActionSemanticLabel(action)): () =>
              widget.onAction(action),
      },
      child: GestureDetector(
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (_) => _finishDrag(),
        onHorizontalDragCancel: _finishDrag,
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: widget.mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_open)
              _SwipeActionRow(
                key: ValueKey('swipe-actions-${widget.messageId}'),
                mine: widget.mine,
                actions: widget.actions,
                onAction: widget.onAction,
              ),
            AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(offset, 0, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

/// The row of separate SIS action boxes shown above an open bubble.
class _SwipeActionRow extends StatelessWidget {
  const _SwipeActionRow({
    super.key,
    required this.mine,
    required this.actions,
    required this.onAction,
  });

  final bool mine;
  final List<MessageAction> actions;
  final ValueChanged<MessageAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          children: [
            for (final action in actions)
              Material(
                key: ValueKey('action-${swipeActionKeyId(action)}'),
                color: scheme.surfaceContainerHighest,
                elevation: 1,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onAction(action),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          swipeActionIcon(action),
                          size: 20,
                          color: action == MessageAction.delete
                              ? scheme.error
                              : scheme.onSurface,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          swipeActionLabel(action),
                          style: TextStyle(
                            fontSize: 11,
                            color: action == MessageAction.delete
                                ? scheme.error
                                : scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

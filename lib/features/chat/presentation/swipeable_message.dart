import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../app/directed_drag.dart';
import '../domain/message.dart';

/// How far left (logical px) a bubble must be dragged before release
/// replies and the haptic tick fires. Well past an accidental scroll's
/// horizontal jitter.
const double replySwipeThreshold = 64.0;

/// The furthest the bubble follows the finger.
const double _replySwipeMax = 96.0;

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

/// Wraps a message bubble so it can be dragged LEFT to reply (offered only when
/// [actions] contains [MessageAction.reply]); a right drag is deliberately not handled
/// here, it belongs to the page's swipe-back; actions also feed screen-reader custom
/// actions; skips every gesture but tap when [actions] is empty.
class SwipeableMessage extends StatefulWidget {
  const SwipeableMessage({
    super.key,
    required this.messageId,
    required this.actions,
    required this.onReply,
    required this.onAction,
    required this.child,
    this.onTap,
  });

  /// The message this bubble belongs to.
  final String messageId;

  /// The actions this message allows right now; empty disables the gestures.
  final List<MessageAction> actions;

  /// Called when the bubble is dragged left past [replySwipeThreshold] and released.
  final VoidCallback onReply;

  /// Called when a screen-reader custom action is chosen.
  final ValueChanged<MessageAction> onAction;

  /// Called on a tap on the bubble (photo, link and quote taps win over it).
  final VoidCallback? onTap;

  final Widget child;

  @override
  State<SwipeableMessage> createState() => _SwipeableMessageState();
}

class _SwipeableMessageState extends State<SwipeableMessage> {
  double _pull = 0;
  bool _dragging = false;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    // Long-press is reserved (v0.42): a no-op competes with the tap so a long
    // hold opens nothing.
    Widget tap(Widget child) => GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onTap: widget.onTap,
      onLongPress: () {},
      child: child,
    );
    if (widget.actions.isEmpty) {
      return widget.onTap == null ? widget.child : tap(widget.child);
    }
    final canReply = widget.actions.contains(MessageAction.reply);
    final scheme = Theme.of(context).colorScheme;
    final progress = (_pull / replySwipeThreshold).clamp(0.0, 1.0);
    final content = tap(
      Stack(
        fit: StackFit.passthrough,
        children: [
          if (_pull > 0)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Opacity(
                    opacity: progress,
                    child: Transform.scale(
                      scale: 0.5 + 0.5 * progress,
                      child: Icon(
                        swipeActionIcon(MessageAction.reply),
                        size: 24,
                        color: _armed
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(-_pull, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
    return Semantics(
      customSemanticsActions: {
        for (final a in widget.actions)
          CustomSemanticsAction(label: swipeActionSemanticLabel(a)): () =>
              widget.onAction(a),
      },
      child: canReply
          ? RawGestureDetector(
              gestures: {
                DirectedDragRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      DirectedDragRecognizer
                    >(
                      () => DirectedDragRecognizer(
                        direction: -1,
                        debugOwner: this,
                      ),
                      (r) {
                        r
                          ..onStart = _onStart
                          ..onUpdate = _onUpdate
                          ..onEnd = _onEnd
                          ..onCancel = _onCancel;
                      },
                    ),
              },
              child: content,
            )
          : content,
    );
  }

  void _onStart(DragStartDetails _) {
    _dragging = true;
    _pull = 0;
    _armed = false;
  }

  void _onUpdate(DragUpdateDetails d) {
    setState(() {
      _pull = (_pull - d.delta.dx).clamp(0.0, _replySwipeMax);
      final armed = _pull >= replySwipeThreshold;
      if (armed && !_armed) HapticFeedback.selectionClick();
      _armed = armed;
    });
  }

  void _onEnd(DragEndDetails _) {
    final reply = _armed;
    _reset();
    if (reply) widget.onReply();
  }

  void _onCancel() => _reset();

  void _reset() {
    setState(() {
      _dragging = false;
      _pull = 0;
      _armed = false;
    });
  }
}

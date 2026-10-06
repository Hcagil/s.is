import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../app/directed_drag.dart';
import '../../../app/grey_option.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../notifications/domain/notification_settings.dart';
import '../../notifications/presentation/notification_pages.dart';
import 'message_menu_card.dart';

/// Shows a chat menu card at [anchor] and returns the selected mute length,
/// or 'off' to unmute, or null if cancelled.
Future<String?> showChatMenuCard(
  BuildContext context, {
  required Rect anchor,
  required bool muted,
}) => showFloatingCard<String>(
  context,
  anchor: anchor,
  cardKey: const ValueKey('chat-menu'),
  child: _ChatMenuBody(muted: muted),
);

class _ChatMenuBody extends StatefulWidget {
  const _ChatMenuBody({required this.muted});

  final bool muted;

  @override
  State<_ChatMenuBody> createState() => _ChatMenuBodyState();
}

class _ChatMenuBodyState extends State<_ChatMenuBody> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          key: const ValueKey('chat-menu-mute'),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  widget.muted
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_outlined,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(l.chatMenuMute)),
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(Icons.chevron_right, size: 20),
                ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          if (widget.muted)
            _MenuRow(
              key: const ValueKey('chat-mute-off'),
              label: l.chatMenuUnmute,
              onTap: () => Navigator.of(context).pop('off'),
            ),
          for (final m in MuteLength.values)
            _MenuRow(
              key: ValueKey('chat-mute-${m.name}'),
              label: muteLengthLabel(l, m),
              onTap: () => Navigator.of(context).pop(m.name),
            ),
        ],
        GreyOption(
          name: 'pin',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.push_pin_outlined, size: 22),
                const SizedBox(width: 14),
                Expanded(child: Text(l.chatMenuPin)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(52, 10, 16, 10),
      child: Text(label),
    ),
  );
}

/// How far left (logical px) a row must be dragged before releasing commits
/// the swipe (and the haptic fires).
const double swipeCommitLine = 70.0;

/// A chat row that archives (or, on the Archived screen, unarchives) when
/// dragged left past [swipeCommitLine] and released. It follows the finger in
/// the same frame; released earlier, it springs back.
class ChatRowSwipe extends StatefulWidget {
  const ChatRowSwipe({
    super.key,
    required this.id,
    required this.label,
    required this.onCommit,
    required this.child,
  });

  /// Conversation id, used in the widget keys.
  final String id;

  /// Pill text, also the screen-reader action name.
  final String label;
  final VoidCallback onCommit;
  final Widget child;

  @override
  State<ChatRowSwipe> createState() => _ChatRowSwipeState();
}

class _ChatRowSwipeState extends State<ChatRowSwipe> {
  static const _reach = 120.0;
  double _pull = 0;
  bool _dragging = false;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: widget.label): widget.onCommit,
      },
      child: RawGestureDetector(
        key: ValueKey('archive-swipe-${widget.id}'),
        gestures: {
          DirectedDragRecognizer:
              GestureRecognizerFactoryWithHandlers<DirectedDragRecognizer>(
                () => DirectedDragRecognizer(direction: -1, debugOwner: this),
                (r) {
                  r
                    ..onStart = _onStart
                    ..onUpdate = _onUpdate
                    ..onEnd = _onEnd
                    ..onCancel = _onCancel;
                },
              ),
        },
        child: Stack(
          children: [
            if (_pull > 0)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Container(
                      key: ValueKey('archive-pill-${widget.id}'),
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _armed ? null : scheme.surfaceContainerHighest,
                        gradient: _armed ? t.gradient : null,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          color: _armed
                              ? Colors.white
                              : scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(-_pull, 0, 0),
              child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onStart(DragStartDetails _) => setState(() {
    _dragging = true;
    _pull = 0;
    _armed = false;
  });

  void _onUpdate(DragUpdateDetails d) => setState(() {
    _pull = (_pull - d.delta.dx).clamp(0.0, _reach);
    final armed = _pull >= swipeCommitLine;
    if (armed && !_armed) HapticFeedback.heavyImpact();
    _armed = armed;
  });

  void _onEnd(DragEndDetails _) {
    final commit = _armed;
    if (commit) widget.onCommit();
    _reset();
  }

  void _onCancel() => _reset();

  void _reset() => setState(() {
    _dragging = false;
    _pull = 0;
    _armed = false;
  });
}

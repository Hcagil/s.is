import 'package:flutter/material.dart';

import '../../../app/grey_option.dart';
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

/// A chat row that can be swiped to reveal a greyed Archive pill. Archiving
/// does not exist yet: the row only springs back.
class ChatRowSwipe extends StatefulWidget {
  const ChatRowSwipe({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  State<ChatRowSwipe> createState() => _ChatRowSwipeState();
}

class _ChatRowSwipeState extends State<ChatRowSwipe> {
  double _dx = 0;
  bool _dragging = false;
  static const _reach = 96.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (_dx < 0)
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GreyOption(
                  name: 'archive',
                  child: Container(
                    key: ValueKey('archive-pill-${widget.id}'),
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(AppLocalizations.of(context).chatArchive),
                  ),
                ),
              ),
            ),
          ),
        GestureDetector(
          key: ValueKey('archive-swipe-${widget.id}'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (d) => setState(
            () => _dx = (_dx + d.delta.dx).clamp(-_reach, 0.0).toDouble(),
          ),
          onHorizontalDragEnd: (_) => setState(() {
            _dragging = false;
            _dx = 0;
          }),
          onHorizontalDragCancel: () => setState(() {
            _dragging = false;
            _dx = 0;
          }),
          child: AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

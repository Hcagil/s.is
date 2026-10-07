import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import 'chat_text_scale.dart';
import 'chat_wallpaper.dart';

/// Two sample bubbles that follow the chosen theme and chat text size live.
class ChatPreview extends StatelessWidget {
  const ChatPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ClipRect(
      child: Stack(
        key: const ValueKey('chat-preview'),
        children: [
          const Positioned.fill(child: ChatWallpaper()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: ChatTextScale(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  _Bubble(text: l.previewTheirs, mine: false),
                  _Bubble(text: l.previewMine, mine: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.mine});

  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(t.bubbleRadius),
            gradient: mine ? t.mineGradient : null,
            color: mine ? null : t.theirs,
            border: mine ? null : Border.all(color: t.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              text,
              style: TextStyle(color: mine ? Colors.white : t.text),
            ),
          ),
        ),
      ),
    );
  }
}

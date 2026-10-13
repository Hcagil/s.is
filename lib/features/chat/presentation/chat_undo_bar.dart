import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_delete_controller.dart';

/// The 5 s bar after a chat delete: what happened, the seconds left, Undo.
class ChatUndoBar extends ConsumerWidget {
  const ChatUndoBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(chatDeleteProvider);
    final notice = s.notice;
    if (notice == null) return const SizedBox.shrink();

    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);

    final message = switch (notice) {
      ChatDeleteNotice.chat => l.chatDeletedUndo,
      ChatDeleteNotice.chats => l.chatsDeletedUndo,
      ChatDeleteNotice.groupLeft => l.chatGroupLeftUndo,
      ChatDeleteNotice.groupDeleted => l.chatGroupDeletedUndo,
    };

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            key: const ValueKey('chat-undo-bar'),
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: t.surfaceHigh,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.line),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x8C000000),
                  blurRadius: 30,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: t.text, fontSize: 14),
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: const Size.square(24),
                        painter: _RingPainter(s.secondsLeft / 5, t.brand),
                      ),
                      Text(
                        '${s.secondsLeft}',
                        style: TextStyle(
                          color: t.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('chat-undo-button'),
                  onPressed: () => ref.read(chatDeleteProvider.notifier).undo(),
                  child: Text(
                    l.chatDeleteUndo,
                    style: TextStyle(
                      color: t.brand,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An arc that shrinks as the seconds run out.
class _RingPainter extends CustomPainter {
  const _RingPainter(this.value, this.color);

  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      (Offset.zero & size).deflate(1),
      -math.pi / 2,
      2 * math.pi * value,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color;
}

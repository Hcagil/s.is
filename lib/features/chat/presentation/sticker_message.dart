import 'package:flutter/material.dart';

import '../domain/message.dart';
import 'sticker_image.dart';

/// A sticker message in a chat: about 160 px, no bubble, the time and tick
/// underneath.
class StickerMessage extends StatelessWidget {
  /// [time] is the time and tick widget, already coloured by the caller.
  const StickerMessage({
    super.key,
    required this.message,
    required this.mine,
    required this.time,
  });

  /// The sticker message ([Message.stickerId] is set).
  final Message message;

  /// Whether the member sent it (it sits at the right).
  final bool mine;

  /// The time and tick widget.
  final Widget time;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey('sticker-${message.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: message.isPending ? 0.6 : 1,
          child: StickerImage(stickerId: message.stickerId!, size: 160),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
          child: time,
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_settings_controller.dart';
import '../application/message_notice_controller.dart';
import 'message_notice.dart';

/// Draws the top card over the whole app, above the Navigator. It shows for 4
/// seconds, a swipe up closes it, a tap calls [onOpen].
class MessageNoticeHost extends ConsumerStatefulWidget {
  /// Creates the host around [child] (the Navigator).
  const MessageNoticeHost({super.key, required this.child, this.onOpen});

  /// The app below the card.
  final Widget child;

  /// Called with the chat id when the card is tapped.
  final void Function(String conversationId)? onOpen;

  @override
  ConsumerState<MessageNoticeHost> createState() => _MessageNoticeHostState();
}

class _MessageNoticeHostState extends ConsumerState<MessageNoticeHost>
    with SingleTickerProviderStateMixin {
  MessageNoticeData? _shown;
  late final AnimationController _ctrl;
  late final Animation<double> _anim = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeOut,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep these loaded so the controller can read mutes and the preview
    // setting at once, with no network wait.
    ref.watch(mutesProvider);
    ref.watch(notificationSettingsProvider);
    ref.listen(messageNoticeProvider, (prev, next) {
      if (next != null) {
        setState(() => _shown = next);
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 4), _close);
        _ctrl.forward();
      } else {
        _ctrl.reverse().then((_) {
          if (mounted && ref.read(messageNoticeProvider) == null) {
            setState(() => _shown = null);
          }
        });
      }
    });

    return Stack(
      children: [
        widget.child,
        if (_shown != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: FadeTransition(
                opacity: _anim,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, -0.2),
                    end: Offset.zero,
                  ).animate(_anim),
                  child: GestureDetector(
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < -100) _close();
                    },
                    child: MessageNoticeCard(
                      data: _shown!,
                      onTap: () {
                        widget.onOpen?.call(_shown!.conversationId);
                        _close();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _close() {
    _timer?.cancel();
    ref.read(messageNoticeProvider.notifier).dismiss();
  }
}

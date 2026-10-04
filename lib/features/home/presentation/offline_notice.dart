import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../auth/application/session_controller.dart';
import '../../chat/application/chat_controllers.dart';

/// The one strip on Home when the server could not be reached and the chats
/// on screen are the saved ones, whichever layer noticed it (the session
/// check or the list read): two causes, one message, never two strips.
class OfflineNotice extends ConsumerWidget {
  const OfflineNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show =
        ref.watch(sessionCheckFailedProvider) ||
        ref.watch(conversationListStaleProvider);
    if (!show) return const SizedBox.shrink();
    final t = SisBrand.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        key: const ValueKey('offline-notice'),
        decoration: BoxDecoration(
          color: t.surfaceHigh,
          border: Border(bottom: BorderSide(color: t.line)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 16, color: t.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Can't reach SIS. Showing your saved chats; trying again.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

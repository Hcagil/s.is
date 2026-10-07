import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/pin_controller.dart';
import '../domain/message.dart';

/// The bar under the chat header that shows the conversation's pinned
/// message (its text, or "Photo"). A tap hands the message to [onTap], which
/// scrolls to it. Nothing shows while no message is pinned or the pinned one
/// is gone.
class PinnedBar extends ConsumerWidget {
  const PinnedBar({
    super.key,
    required this.conversationId,
    required this.onTap,
  });

  final String conversationId;
  final ValueChanged<Message> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(pinnedMessageProvider(conversationId)).value;
    if (message == null || message.isDeleted) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: scheme.surfaceContainerHigh,
          child: InkWell(
            key: const ValueKey('pinned-bar'),
            onTap: () => onTap(message),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.push_pin, size: 18, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l.pinnedBarTitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          message.body.isNotEmpty
                              ? message.body
                              : l.pinnedBarPhoto,
                          key: const ValueKey('pinned-bar-text'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

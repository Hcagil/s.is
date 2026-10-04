import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../application/session_controller.dart';

/// A small strip on Home while the stored session could not be confirmed
/// because the server did not answer; the saved chats stay usable and the
/// controller keeps retrying.
class SessionCheckNotice extends ConsumerWidget {
  const SessionCheckNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sessionCheckFailedProvider)) return const SizedBox.shrink();
    final t = SisBrand.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        key: const ValueKey('session-check-notice'),
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

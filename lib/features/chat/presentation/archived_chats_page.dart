import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/archive_providers.dart';
import 'conversation_tile.dart';

/// The "Archived chats" row above the chat list. Opens [ArchivedChatsPage];
/// a small count shows how many archived chats have something unread.
class ArchivedChatsRow extends ConsumerWidget {
  const ArchivedChatsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final unread = ref.watch(archivedUnreadCountProvider);
    return InkWell(
      key: const ValueKey('archived-chats-row'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ArchivedChatsPage()),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.archive_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                l.archivedChatsTitle,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              if (unread > 0) ...[
                const SizedBox(width: 8),
                Container(
                  key: const ValueKey('archived-count'),
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '$unread',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The archived chats, from the stored list (no loading step). Rows swipe to
/// unarchive.
class ArchivedChatsPage extends ConsumerWidget {
  const ArchivedChatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final chats = ref.watch(archivedChatsProvider);
    return Scaffold(
      key: const ValueKey('archived-chats-page'),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.archivedChatsTitle),
            Text(
              l.archivedChatsCount(chats.length),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              l.archivedChatsHint,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: chats.isEmpty
                ? Center(
                    child: Text(
                      l.archivedChatsEmpty,
                      key: const ValueKey('archived-empty'),
                    ),
                  )
                : ListView.separated(
                    itemCount: chats.length,
                    separatorBuilder: (_, _) => const FadeDivider(),
                    itemBuilder: (context, i) => ConversationTile(
                      chats[i],
                      inArchive: true,
                      key: ValueKey('archived-tile-${chats[i].id}'),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

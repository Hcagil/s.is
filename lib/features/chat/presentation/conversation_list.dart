import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../core/startup_marks.dart';
import '../application/archive_providers.dart';
import 'archive_reveal_list.dart';
import 'archived_chats_page.dart';
import '../domain/message.dart';
import '../application/chat_controllers.dart';
import '../domain/conversation.dart';
import '../domain/highlight.dart';
import 'member_name.dart';
import 'message_screen.dart';
import 'new_chat_page.dart';
import 'new_group_page.dart';
import 'person_avatar.dart';
import '../../../l10n/app_localizations.dart';
import 'conversation_tile.dart';

/// The member's conversations, newest first, with a picker for starting one.
class ConversationList extends ConsumerWidget {
  const ConversationList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final conversations = ref.watch(conversationListProvider);
    final hasArchived = ref.watch(
      archivedChatsProvider.select((a) => a.isNotEmpty),
    );
    final searchQuery = ref.watch(
      chatListSearchProvider.select((s) => s.query),
    );
    // A search failure keeps whatever results were already on screen; only
    // the notice is new.
    ref.listen(chatListSearchProvider.select((s) => s.failure), (
      previous,
      next,
    ) {
      if (next != null) showSisNotice(context, next.message, isError: true);
    });
    // Debug timing only (label, never data): first build that has rows.
    if (conversations.value?.isNotEmpty ?? false) {
      StartupMarks.mark('list-rows');
    }

    return Scaffold(
      body: Column(
        children: [
          const _ListSearchField(),
          Expanded(
            child: !isSearchable(searchQuery)
                ? switch (conversations) {
                    AsyncData(:final value) when value.isEmpty =>
                      const _Empty(),
                    AsyncData(:final value) => _visibleList(
                      context,
                      ref,
                      value,
                      hasArchived,
                    ),
                    AsyncError(:final error) => _Failed(
                      reason: failureReason(error),
                      onRetry: () =>
                          ref.read(conversationListProvider.notifier).refresh(),
                    ),
                    _ => const Center(child: SisLoadingLogo(size: 40)),
                  }
                : const _SearchResults(),
          ),
        ],
      ),
      floatingActionButton: Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          FloatingActionButton.extended(
            key: const ValueKey('new-group'),
            heroTag: 'new-group',
            onPressed: () => _startGroup(context, ref),
            icon: const Icon(Icons.groups_outlined),
            label: Text(l.commonNewGroup),
          ),
          FloatingActionButton.extended(
            key: const ValueKey('new-chat'),
            heroTag: 'new-chat',
            onPressed: () => _startChat(context, ref),
            icon: const Icon(Icons.edit_outlined),
            label: Text(l.pickerNewChat),
          ),
        ],
      ),
    );
  }
}

/// The un-archived chats; the "Archived chats" row hides above them while
/// anything is archived (when every chat is archived, the row shows alone).
Widget _visibleList(
  BuildContext context,
  WidgetRef ref,
  List<Conversation> all,
  bool hasArchived,
) {
  final l = AppLocalizations.of(context);
  final shown = [
    for (final c in all)
      if (!c.archived) c,
  ];
  final pinned = [
    for (final c in shown)
      if (c.pinned) c,
  ];
  final rest = [
    for (final c in shown)
      if (!c.pinned) c,
  ];
  // A row is a Conversation, or a String section header (only while
  // something is pinned).
  final rows = <Object>[
    if (pinned.isNotEmpty) ...[
      l.listPinnedHeader,
      ...pinned,
      if (rest.isNotEmpty) l.listChatsHeader,
    ],
    ...rest,
  ];
  return ArchiveRevealList(
    header: hasArchived ? const ArchivedChatsRow() : null,
    itemCount: rows.length,
    separatorBuilder: (_, i) => rows[i] is String || rows[i + 1] is String
        ? const SizedBox.shrink()
        : const FadeDivider(),
    itemBuilder: (context, i) => switch (rows[i]) {
      final String text => _SectionHeader(
        text,
        key: ValueKey('list-header-$i'),
      ),
      final Conversation c => ConversationTile(c),
      _ => const SizedBox.shrink(),
    },
    onRefresh: () => ref.read(conversationListProvider.notifier).refresh(),
  );
}

/// "Pinned" / "Chats" above a group of rows, shown only while a chat is
/// pinned.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Future<void> _startChat(BuildContext context, WidgetRef ref) async {
  final picked = await showNewChatPage(context);
  if (picked == null || !context.mounted) return;

  final result = await ref
      .read(conversationListProvider.notifier)
      .startWith(picked.userId);
  if (!context.mounted) return;
  switch (result) {
    case Ok(:final value):
      await openConversation(
        context,
        ref,
        value,
        title: picked.displayName,
        otherUserId: picked.userId,
      );
    case Err(:final failure):
      showSisNotice(context, failure.message, isError: true);
  }
}

Future<void> _startGroup(BuildContext context, WidgetRef ref) async {
  final picked = await showNewGroupPage(context);
  if (picked == null || !context.mounted) return;

  final result = await ref
      .read(conversationListProvider.notifier)
      .startGroup(
        title: picked.title,
        memberIds: [for (final m in picked.members) m.userId],
      );
  if (!context.mounted) return;
  switch (result) {
    case Ok(:final value):
      await openConversation(
        context,
        ref,
        value,
        title: picked.title,
        group: true,
      );
    case Err(:final failure):
      showSisNotice(context, failure.message, isError: true);
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        AppLocalizations.of(context).listEmpty,
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.reason, required this.onRetry});

  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(reason, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: onRetry,
            child: Text(AppLocalizations.of(context).commonTryAgain),
          ),
        ],
      ),
    ),
  );
}

/// "Search messages" above the chat list. Typing (debounced by the
/// controller) replaces the list with [_SearchResults]; clearing it goes
/// back to the plain list.
class _ListSearchField extends ConsumerStatefulWidget {
  const _ListSearchField();

  @override
  ConsumerState<_ListSearchField> createState() => _ListSearchFieldState();
}

class _ListSearchFieldState extends ConsumerState<_ListSearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        key: const ValueKey('list-search-field'),
        controller: _controller,
        onChanged: (text) {
          ref.read(chatListSearchProvider.notifier).search(text);
          setState(() {}); // only to show/hide the clear button below
        },
        decoration: InputDecoration(
          hintText: l.listSearchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _controller.clear();
                    ref.read(chatListSearchProvider.notifier).clear();
                    setState(() {});
                  },
                ),
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Hits across every conversation for the chat list's own search box, newest
/// first: each row names the conversation the hit is in (not the sender),
/// with its snippet's matched text highlighted.
class _SearchResults extends ConsumerWidget {
  const _SearchResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(chatListSearchProvider);
    final conversations = {
      for (final c in ref.watch(conversationListProvider).value ?? const [])
        c.id: c,
    };
    if (state.results.isEmpty) {
      return Center(child: Text(l.listNoResults));
    }
    return ListView.separated(
      itemCount: state.results.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        final message = state.results[i];
        final conversation = conversations[message.conversationId];
        final label = conversation == null
            ? l.listConversation
            : conversationLabel(l, conversation);
        final seed =
            conversation?.other?.userId ??
            conversation?.id ??
            message.conversationId;
        return ListTile(
          key: ValueKey('list-search-result-${message.id}'),
          leading: PersonAvatar(
            label: label,
            seed: seed,
            avatarPath:
                conversation?.avatarPath ?? conversation?.other?.avatarPath,
          ),
          title: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text.rich(
            TextSpan(
              children: _highlighted(
                previewText(message),
                state.query,
                context,
              ),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(previewTime(message.createdAt, DateTime.now())),
          onTap: () => openConversation(
            context,
            ref,
            message.conversationId,
            title: conversation == null
                ? null
                : conversationLabel(l, conversation),
            otherUserId: conversation?.other?.userId,
            group: conversation?.isGroup ?? false,
            searchQuery: state.query,
            searchHitId: message.id,
          ),
        );
      },
    );
  }

  /// [text] as spans, with every case-insensitive occurrence of [query]
  /// styled as a highlight.
  List<TextSpan> _highlighted(String text, String query, BuildContext context) {
    final offsets = matchOffsets(text, query);
    if (offsets.isEmpty) return [TextSpan(text: text)];
    final length = query.trim().length;
    final highlight = TextStyle(
      fontWeight: FontWeight.w800,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final start in offsets) {
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(
        TextSpan(text: text.substring(start, start + length), style: highlight),
      );
      cursor = start + length;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return spans;
  }
}

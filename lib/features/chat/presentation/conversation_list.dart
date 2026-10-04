import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../core/startup_marks.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/message.dart';
import '../../presence/application/presence_controllers.dart';
import '../application/chat_controllers.dart';
import '../domain/conversation.dart';
import '../domain/highlight.dart';
import 'message_screen.dart';
import 'new_chat_page.dart';
import 'new_group_page.dart';
import 'person_avatar.dart';

/// The member's conversations, newest first, with a picker for starting one.
class ConversationList extends ConsumerWidget {
  const ConversationList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationListProvider);
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
                    AsyncData(:final value) => RefreshIndicator(
                      onRefresh: () =>
                          ref.read(conversationListProvider.notifier).refresh(),
                      child: ListView.separated(
                        itemCount: value.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) =>
                            _ConversationTile(value[i]),
                      ),
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
            label: const Text('New group'),
          ),
          FloatingActionButton.extended(
            key: const ValueKey('new-chat'),
            heroTag: 'new-chat',
            onPressed: () => _startChat(context, ref),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('New chat'),
          ),
        ],
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

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile(this.conversation);

  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Whose messages are "mine" comes from the session, as on the message
    // screen.
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    final scheme = Theme.of(context).colorScheme;
    final unread = conversation.unread > 0;
    // A group left or been removed from: read-only history, nothing new can
    // ever arrive, so the tile is greyed like a departed member's name
    // elsewhere in that same group.
    final left = conversation.hasLeft;
    // A group row names its last sender, in their colour in that group.
    final voice =
        conversation.isGroup &&
            !conversation.isSystem &&
            conversation.lastSenderId != me
        ? conversation.senders[conversation.lastSenderId]
        : null;
    final previewStyle = unread
        ? TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600)
        : left
        ? TextStyle(color: scheme.onSurfaceVariant)
        : null;
    return ListTile(
      key: ValueKey('conversation-${conversation.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      leading: PersonAvatar(
        label: conversation.label,
        // A person keeps one tint everywhere; a group has its own.
        seed: conversation.other?.userId ?? conversation.id,
        online:
            conversation.other != null &&
            ref
                .watch(onlineMembersProvider)
                .contains(conversation.other!.userId),
        dotKey: ValueKey('online-${conversation.id}'),
        avatarPath: conversation.avatarPath ?? conversation.other?.avatarPath,
      ),
      title: Text(
        conversation.label,
        key: left ? ValueKey('left-${conversation.id}') : null,
        style: TextStyle(
          fontWeight: unread ? FontWeight.w800 : FontWeight.w700,
          color: left ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: conversation.lastMessage == null
          ? const Text('No messages yet')
          : voice != null
          ? Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: voice.name,
                    style: TextStyle(
                      color: groupColor(context, voice.slot),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: ': ${conversation.lastMessage}'),
                ],
              ),
              key: ValueKey('preview-${conversation.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: previewStyle,
            )
          : Text(
              conversation.lastSenderId != null &&
                      conversation.lastSenderId == me
                  ? 'You: ${conversation.lastMessage}'
                  : conversation.lastMessage!,
              key: ValueKey('preview-${conversation.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: previewStyle,
            ),
      trailing: conversation.lastMessageAt == null
          ? null
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  previewTime(conversation.lastMessageAt!, DateTime.now()),
                  key: ValueKey('preview-time-${conversation.id}'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: unread ? scheme.primary : null,
                    fontWeight: unread ? FontWeight.w700 : null,
                  ),
                ),
                if (unread) ...[
                  const SizedBox(height: 4),
                  Container(
                    key: ValueKey('unread-${conversation.id}'),
                    // No `alignment`: an aligned Container grows to all the
                    // width it is offered, and a ListTile trailing is offered
                    // the whole row. Sized by its text, at least round.
                    constraints: const BoxConstraints(minWidth: 20),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      conversation.unread > 99
                          ? '99+'
                          : '${conversation.unread}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
      onTap: () => openConversation(
        context,
        ref,
        conversation.id,
        title: conversation.label,
        otherUserId: conversation.other?.userId,
        group: conversation.isGroup,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'No conversations yet.\nStart one with New chat.',
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
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
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
          hintText: 'Search messages',
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
    final state = ref.watch(chatListSearchProvider);
    final conversations = {
      for (final c in ref.watch(conversationListProvider).value ?? const [])
        c.id: c,
    };
    if (state.results.isEmpty) {
      return const Center(child: Text('No messages found'));
    }
    return ListView.separated(
      itemCount: state.results.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        final message = state.results[i];
        final conversation = conversations[message.conversationId];
        final label = conversation?.label ?? 'Conversation';
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
            title: conversation?.label,
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

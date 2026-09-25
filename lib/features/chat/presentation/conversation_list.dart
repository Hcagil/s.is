import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/message.dart';
import '../../presence/application/presence_controllers.dart';
import '../application/chat_controllers.dart';
import '../domain/conversation.dart';
import 'message_screen.dart';
import 'person_avatar.dart';

/// Reason text for any failure, so a screen never shows a bare exception.
String reasonOf(Object error) =>
    error is Failure ? error.message : error.toString();

/// The member's conversations, newest first, with a picker for starting one.
class ConversationList extends ConsumerWidget {
  const ConversationList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationListProvider);
    return Scaffold(
      body: switch (conversations) {
        AsyncData(:final value) when value.isEmpty => const _Empty(),
        AsyncData(:final value) => RefreshIndicator(
          onRefresh: () =>
              ref.read(conversationListProvider.notifier).refresh(),
          child: ListView.separated(
            itemCount: value.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, i) => _ConversationTile(value[i]),
          ),
        ),
        AsyncError(:final error) => _Failed(
          reason: reasonOf(error),
          onRetry: () => ref.read(conversationListProvider.notifier).refresh(),
        ),
        _ => const Center(child: SisLoadingLogo(size: 40)),
      },
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            key: const ValueKey('new-group'),
            heroTag: 'new-group',
            onPressed: () => _startGroup(context, ref),
            icon: const Icon(Icons.groups_outlined),
            label: const Text('New group'),
          ),
          const SizedBox(width: 12),
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
  final picked = await showModalBottomSheet<Member>(
    context: context,
    builder: (_) => const _MemberPicker(),
  );
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
  final picked =
      await showModalBottomSheet<({String title, List<Member> members})>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const _GroupComposer(),
      );
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

/// Title plus at least one other member. Both are required, so the button
/// stays disabled rather than letting the server refuse the call.
class _GroupComposer extends ConsumerStatefulWidget {
  const _GroupComposer();

  @override
  ConsumerState<_GroupComposer> createState() => _GroupComposerState();
}

class _GroupComposerState extends ConsumerState<_GroupComposer> {
  final _title = TextEditingController();
  final _chosen = <Member>{};

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);
    final ready = _title.text.trim().isNotEmpty && _chosen.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('group-title'),
              controller: _title,
              maxLength: 80,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Group name',
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: switch (members) {
                AsyncData(:final value) when value.isEmpty => const ListTile(
                  title: Text('Nobody else has signed in yet'),
                ),
                AsyncData(:final value) => ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in value)
                      CheckboxListTile(
                        key: ValueKey('group-member-${m.userId}'),
                        value: _chosen.any((c) => c.userId == m.userId),
                        title: Text(m.displayName),
                        subtitle: m.tag == null ? null : Text('@${m.tag}'),
                        onChanged: (on) => setState(() {
                          if (on ?? false) {
                            _chosen.add(m);
                          } else {
                            _chosen.removeWhere((c) => c.userId == m.userId);
                          }
                        }),
                      ),
                  ],
                ),
                AsyncError(:final error) => ListTile(
                  title: Text(reasonOf(error)),
                ),
                _ => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: SisLoadingLogo(size: 40)),
                ),
              },
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('group-create'),
              onPressed: ready
                  ? () => Navigator.of(context).pop((
                      title: _title.text.trim(),
                      members: _chosen.toList(),
                    ))
                  : null,
              child: const Text('Create group'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberPicker extends ConsumerWidget {
  const _MemberPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider);
    return SafeArea(
      child: switch (members) {
        AsyncData(:final value) when value.isEmpty => const ListTile(
          title: Text('Nobody else has signed in yet'),
        ),
        AsyncData(:final value) => ListView(
          shrinkWrap: true,
          children: [
            for (final m in value)
              ListTile(
                key: ValueKey('member-${m.userId}'),
                leading: PersonAvatar(
                  label: m.displayName,
                  seed: m.userId,
                  online: false,
                  dotKey: ValueKey('picker-online-${m.userId}'),
                ),
                title: Text(m.displayName),
                subtitle: m.tag == null ? null : Text('@${m.tag}'),
                onTap: () => Navigator.of(context).pop(m),
              ),
          ],
        ),
        AsyncError(:final error) => ListTile(title: Text(reasonOf(error))),
        _ => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: SisLoadingLogo(size: 40)),
        ),
      },
    );
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
      ),
      title: Text(
        conversation.label,
        style: TextStyle(
          fontWeight: unread ? FontWeight.w800 : FontWeight.w700,
        ),
      ),
      subtitle: conversation.lastMessage == null
          ? const Text('No messages yet')
          : Text(
              conversation.lastSenderId != null &&
                      conversation.lastSenderId == me
                  ? 'You: ${conversation.lastMessage}'
                  : conversation.lastMessage!,
              key: ValueKey('preview-${conversation.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: unread
                  ? TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    )
                  : null,
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

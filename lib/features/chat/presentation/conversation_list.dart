import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import '../domain/conversation.dart';
import 'message_screen.dart';

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
          child: ListView.builder(
            itemCount: value.length,
            itemBuilder: (context, i) => _ConversationTile(value[i]),
          ),
        ),
        AsyncError(:final error) => _Failed(
          reason: reasonOf(error),
          onRetry: () => ref.read(conversationListProvider.notifier).refresh(),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startChat(context, ref),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New chat'),
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
      await openConversation(context, ref, value, title: picked.displayName);
    case Err(:final failure):
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
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
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(m.displayName),
                onTap: () => Navigator.of(context).pop(m),
              ),
          ],
        ),
        AsyncError(:final error) => ListTile(title: Text(reasonOf(error))),
        _ => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
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
    return ListTile(
      key: ValueKey('conversation-${conversation.id}'),
      leading: const CircleAvatar(child: Icon(Icons.person_outline)),
      title: Text(conversation.other.displayName),
      subtitle: conversation.lastMessage == null
          ? const Text('No messages yet')
          : Text(
              conversation.lastMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () => openConversation(
        context,
        ref,
        conversation.id,
        title: conversation.other.displayName,
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

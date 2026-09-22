import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../chat/application/chat_controllers.dart';
import '../../chat/presentation/conversation_list.dart';
import '../../update/presentation/update_banner.dart';

/// Asks for a new display name and reports any refusal with its reason.
Future<void> _rename(
  BuildContext context,
  WidgetRef ref,
  String current,
) async {
  final controller = TextEditingController(text: current);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Display name'),
      content: TextField(
        key: const ValueKey('display-name-field'),
        controller: controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(counterText: ''),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('display-name-save'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.isEmpty || !context.mounted) return;

  final result = await ref
      .read(conversationListProvider.notifier)
      .setDisplayName(name);
  if (!context.mounted) return;
  if (result case Err(:final failure)) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(failure.message)));
  }
}

/// Home for an allowed member: the update banner, then the conversations.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SIS'),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('home-menu'),
            onSelected: (choice) => switch (choice) {
              'rename' => _rename(context, ref, member.displayName),
              _ => ref.read(sessionControllerProvider.notifier).signOut(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'rename',
                child: Text('Change display name'),
              ),
              PopupMenuItem(
                value: 'sign-out',
                child: Text('Sign out (${member.displayName})'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: const [
            UpdateBanner(),
            Expanded(child: ConversationList()),
          ],
        ),
      ),
    );
  }
}

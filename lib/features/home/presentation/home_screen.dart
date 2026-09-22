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
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(current: current),
  );
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

/// Owns its own controller.
///
/// showDialog's future completes when the route is popped, but the dialog
/// keeps rendering through its exit animation — so disposing the controller
/// at the call site leaves the still-mounted TextField rebuilding against a
/// disposed controller. A State disposes after the route is gone.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Display name'),
      content: TextField(
        key: const ValueKey('display-name-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(counterText: ''),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('display-name-save'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
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

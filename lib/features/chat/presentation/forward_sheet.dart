import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';

/// Lets the member pick one or more chats and sends [message] to each,
/// marked as forwarded.
Future<void> showForwardSheet(
  BuildContext context,
  WidgetRef ref,
  Message message,
) async {
  final chosen = await showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ForwardPicker(exclude: ref.read(openConversationProvider)),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;
  final r = await ref.read(messagesProvider.notifier).forward(message, chosen);
  if (!context.mounted) return;
  showSisNotice(context, switch (r) {
    Ok() =>
      chosen.length == 1 ? 'Forwarded' : 'Forwarded to ${chosen.length} chats',
    Err(:final failure) => failure.message,
  }, isError: r is Err);
}

class _ForwardPicker extends ConsumerStatefulWidget {
  const _ForwardPicker({required this.exclude});

  /// The conversation on screen: forwarding into it again makes no sense.
  final String? exclude;

  @override
  ConsumerState<_ForwardPicker> createState() => _ForwardPickerState();
}

class _ForwardPickerState extends ConsumerState<_ForwardPicker> {
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'Forward to',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('forward-send'),
                  onPressed: _picked.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_picked.toList()),
                  child: Text(
                    _picked.isEmpty ? 'Send' : 'Send (${_picked.length})',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: switch (ref.watch(conversationListProvider)) {
              AsyncData(:final value) => ListView(
                children: [
                  for (final c in value)
                    if (c.id != widget.exclude)
                      CheckboxListTile(
                        key: ValueKey('forward-${c.id}'),
                        value: _picked.contains(c.id),
                        onChanged: (on) => setState(
                          () => on == true
                              ? _picked.add(c.id)
                              : _picked.remove(c.id),
                        ),
                        secondary: Icon(
                          c.isGroup
                              ? Icons.group_outlined
                              : Icons.person_outline,
                        ),
                        title: Text(c.label),
                      ),
                ],
              ),
              AsyncError() => const Center(
                child: Text('Chats could not be loaded.'),
              ),
              _ => const Center(child: SisLoadingLogo(size: 40)),
            },
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import 'conversation_list.dart';

/// Opens [conversationId] and closes it again when the screen is popped, so
/// the Realtime subscription lives exactly as long as the screen does.
Future<void> openConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  String? title,
}) async {
  ref.read(openConversationProvider.notifier).open(conversationId);
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => MessageScreen(title: title)));
  ref.read(openConversationProvider.notifier).close();
}

/// The open conversation: its messages, and a composer.
class MessageScreen extends ConsumerWidget {
  const MessageScreen({super.key, this.title});

  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(messagesProvider);
    // Whose messages are "mine" comes from the session, not from the screen.
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(title: Text(title ?? 'Conversation')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: switch (messages) {
                AsyncData(:final value) when value.isEmpty => const Center(
                  child: Text('No messages yet. Say something.'),
                ),
                AsyncData(:final value) => ListView.builder(
                  // Newest at the bottom, which is where the composer is.
                  reverse: true,
                  itemCount: value.length,
                  itemBuilder: (context, i) {
                    final message = value[value.length - 1 - i];
                    return _Bubble(
                      message,
                      mine: me != null && message.isFrom(me),
                    );
                  },
                ),
                AsyncError(:final error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(reasonOf(error), textAlign: TextAlign.center),
                  ),
                ),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
            const _Composer(),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.message, {required this.mine});

  final Message message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey('message-${message.id}'),
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.body,
          style: TextStyle(
            color: mine ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _Composer extends ConsumerStatefulWidget {
  const _Composer();

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text;
    // The same rule the database enforces, applied before the round trip.
    if (_sending || !isSendableBody(body)) return;
    setState(() => _sending = true);
    final result = await ref.read(messagesProvider.notifier).send(body);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case Ok():
        // Cleared only on success, so nothing a member typed is lost.
        _controller.clear();
      case Err(:final failure):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('composer-field'),
              controller: _controller,
              maxLength: maxMessageLength,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: 'Message',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const ValueKey('composer-send'),
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

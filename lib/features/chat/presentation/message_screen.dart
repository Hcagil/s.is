import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../../presence/application/presence_controllers.dart';
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
  String? otherUserId,
}) async {
  ref.read(openConversationProvider.notifier).open(conversationId);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MessageScreen(title: title, otherUserId: otherUserId),
    ),
  );
  ref.read(openConversationProvider.notifier).close();
  // The list is also kept live by Realtime; this re-read is the fallback when
  // that subscription could not be established.
  await ref.read(conversationListProvider.notifier).reloadQuietly();
}

/// "typing…" beats "online"; in a group, who is typing by name.
String? _status(WidgetRef ref, String? other) {
  final typing = ref.watch(typingProvider);
  if (typing.isNotEmpty) {
    if (typing.length > 1) return '${typing.length} people are typing…';
    final names = {
      for (final m in ref.watch(membersProvider).value ?? const []) m.userId: m,
    };
    final who = names[typing.first]?.displayName;
    return who == null ? 'typing…' : '$who is typing…';
  }
  if (other != null && ref.watch(onlineMembersProvider).contains(other)) {
    return 'online';
  }
  return null;
}

/// The open conversation: its messages, and a composer.
class MessageScreen extends ConsumerWidget {
  const MessageScreen({super.key, this.title, this.otherUserId});

  final String? title;

  /// The other member of a 1:1, whose online status the header shows. Null
  /// for a group, where the header shows only who is typing.
  final String? otherUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(messagesProvider);
    // Whose messages are "mine" comes from the session, not from the screen.
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    // A message from someone ends their "typing…" at once rather than
    // leaving it over the message they just sent.
    ref.listen(messagesProvider, (previous, next) {
      final latest = next.value;
      if (latest == null || latest.isEmpty) return;
      if (previous?.value?.lastOrNull?.id == latest.last.id) return;
      ref.read(typingProvider.notifier).messageFrom(latest.last.senderId);
    });
    final status = _status(ref, otherUserId);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title ?? 'Conversation'),
            if (status != null)
              Text(
                status,
                key: const ValueKey('conversation-status'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.hasAttachment) _Attachment(message.attachmentPath!),
            // An image may be sent without a caption, so an empty body must
            // render nothing at all rather than an empty line.
            if (message.body.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: message.hasAttachment ? 8 : 0),
                child: Text(
                  message.body,
                  style: TextStyle(
                    color: mine
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// An attachment, fetched through a signed URL issued only to a member.
///
/// The URL is short-lived, so it is resolved when the bubble is built rather
/// than stored with the message.
class _Attachment extends ConsumerStatefulWidget {
  const _Attachment(this.path);

  final String path;

  @override
  ConsumerState<_Attachment> createState() => _AttachmentState();
}

class _AttachmentState extends ConsumerState<_Attachment> {
  late final Future<Result<Uri>> _url = ref
      .read(messagesProvider.notifier)
      .attachmentUrl(widget.path);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260, maxWidth: 280),
        child: FutureBuilder<Result<Uri>>(
          future: _url,
          builder: (context, snapshot) => switch (snapshot.data) {
            Ok(:final value) => Image.network(
              value.toString(),
              key: const ValueKey('attachment-image'),
              fit: BoxFit.cover,
              errorBuilder: (context, _, _) => _failed('Image unavailable'),
            ),
            Err(:final failure) => _failed(failure.message),
            _ => const SizedBox(
              height: 120,
              width: 180,
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ),
      ),
    );
  }

  Widget _failed(String reason) => Container(
    height: 96,
    width: 180,
    alignment: Alignment.center,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(reason, textAlign: TextAlign.center),
    ),
  );
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

  /// Picks and sends an image, with whatever is typed as its caption.
  Future<void> _attach() async {
    if (_sending) return;
    setState(() => _sending = true);
    final result = await ref
        .read(messagesProvider.notifier)
        .sendImage(body: _controller.text);
    if (!mounted) return;
    setState(() => _sending = false);
    // null means the member backed out of the picker: not a failure.
    switch (result) {
      case null:
        return;
      case Ok():
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
          IconButton(
            key: const ValueKey('composer-attach'),
            onPressed: _sending ? null : _attach,
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Send a photo',
          ),
          Expanded(
            child: TextField(
              key: const ValueKey('composer-field'),
              controller: _controller,
              maxLength: maxMessageLength,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              // Throttled, and silent when the member does not share typing.
              onChanged: (text) {
                if (text.isNotEmpty) {
                  ref.read(typingProvider.notifier).signalTyping();
                }
              },
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

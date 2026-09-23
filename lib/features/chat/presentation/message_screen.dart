import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../../app/theme.dart';
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
  bool group = false,
}) async {
  final list = ref.read(conversationListProvider.notifier);
  ref.read(openConversationProvider.notifier).open(conversationId);
  // Opening is reading. Not awaited: the screen must not wait on it.
  unawaited(list.markRead(conversationId));
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          MessageScreen(title: title, otherUserId: otherUserId, group: group),
    ),
  );
  // Again on leaving, so a message that landed while the screen was open is
  // read before the list below re-reads the counts.
  await list.markRead(conversationId);
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
  const MessageScreen({
    super.key,
    this.title,
    this.otherUserId,
    this.group = false,
  });

  final String? title;

  /// A group names each sender above their run of messages.
  final bool group;

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
    final names = group
        ? {
            for (final m in ref.watch(membersProvider).value ?? const [])
              m.userId: m.displayName,
          }
        : const <String, String>{};
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
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
      body: SisGlow(
        child: SafeArea(
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
                      final index = value.length - 1 - i;
                      final message = value[index];
                      final mine = me != null && message.isFrom(me);
                      return _Bubble(
                        message,
                        mine: mine,
                        sender: group && !mine && startsRun(value, index)
                            ? (names[message.senderId] ?? 'Member')
                            : null,
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
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.message, {required this.mine, this.sender});

  final Message message;
  final bool mine;

  /// The sender's name, shown above the first bubble of their run in a group.
  final String? sender;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    // Square-ish corner on the sender's side marks whose bubble it is.
    const r = Radius.circular(8);
    const tail = Radius.circular(3);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey('message-${message.id}'),
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? null : brand.theirs,
          gradient: mine ? brand.gradient : null,
          borderRadius: BorderRadius.only(
            topLeft: r,
            topRight: r,
            bottomLeft: mine ? r : tail,
            bottomRight: mine ? tail : r,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sender != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  sender!,
                  key: ValueKey('sender-${message.id}'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: personTint(context, message.senderId, ink: true),
                  ),
                ),
              ),
            if (message.hasAttachment) _Attachment(message.attachmentPath!),
            // An image may be sent without a caption, so an empty body must
            // render nothing at all rather than an empty line.
            if (message.body.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: message.hasAttachment ? 8 : 0),
                child: Text(
                  message.body,
                  style: TextStyle(
                    fontSize: 15,
                    color: mine ? Colors.white : brand.text,
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
      borderRadius: BorderRadius.circular(6),
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
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 10, 12),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('composer-attach'),
            onPressed: _sending ? null : _attach,
            icon: const Icon(Icons.attach_file_rounded),
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
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const ValueKey('composer-send'),
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    );
  }
}

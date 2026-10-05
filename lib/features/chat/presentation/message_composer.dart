part of 'message_screen.dart';

class _Composer extends ConsumerStatefulWidget {
  const _Composer();

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  double _lastInset = 0;

  /// This composer's conversation is fixed for its whole lifetime: opening
  /// a different one always pushes a new [MessageScreen] (see
  /// [openConversation]), never swaps this one's provider underneath it.
  String? _conversationId;

  /// True for the span of code that copies a draft INTO the controller or
  /// [replyingToProvider] -- the two listeners below must not echo that
  /// copy straight back into the draft store as if the member had typed or
  /// replied to it themselves.
  bool _applyingDraft = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final id = ref.read(openConversationProvider);
    _conversationId = id;
    if (id == null) return;
    // Applying the draft touches other providers (replyingToProvider via
    // _applyDraft, draftsProvider via consumeFailure) -- unsafe
    // synchronously here, since initState runs as part of the first build.
    // Deferred to right after that frame: the same restore path build()'s
    // listener below uses when a queued send's failure resolves while this
    // composer is already open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreDraft(id);
    });
  }

  /// Applies [id]'s draft (text + reply target) and shows its pending
  /// failure notice, if any, exactly once. The one restore path, used both
  /// right after opening ([initState]) and while already open (the
  /// [draftsProvider] listener in [build]).
  void _restoreDraft(String id) {
    final drafts = ref.read(draftsProvider.notifier);
    _applyDraft(drafts.draftFor(id));
    final failure = drafts.consumeFailure(id);
    if (failure != null && mounted) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  /// Copies [draft]'s text and reply target onto the composer, without
  /// re-triggering the write-back listeners below (see [_applyingDraft]).
  void _applyDraft(Draft draft) {
    _applyingDraft = true;
    if (_controller.text != draft.text) {
      _controller.text = draft.text;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
    if (draft.replyTo != null) {
      ref.read(replyingToProvider.notifier).start(draft.replyTo!);
    }
    _applyingDraft = false;
  }

  /// The system back gesture closes the keyboard but leaves the field
  /// focused; releasing the focus when the keyboard goes away keeps the
  /// focus and the platform input state in step, so the next back leaves
  /// the page.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = View.of(context).viewInsets.bottom;
    if (_lastInset > 0 && inset == 0 && _focus.hasFocus) _focus.unfocus();
    _lastInset = inset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final body = _controller.text;
    final editing = ref.read(editingProvider);
    // The same rule the database enforces, applied before the round trip. A
    // photo message's caption may be empty; a text-only message may not.
    final bodyOk = editing != null && editing.hasAttachment
        ? body.trim().length <= maxMessageLength
        : isSendableBody(body);
    if (_sending || !bodyOk) return;
    if (editing != null) {
      unawaited(_saveEdit(editing, body));
      return;
    }
    final id = _conversationId;
    if (id == null) return;
    // Optimistic: SendQueueController shows the pending bubble and queues
    // the round trip (retrying on its own if offline); the composer clears
    // at once and does not wait for it, so it stays usable while a send is
    // in flight. It also ends this conversation's draft and the reply
    // target -- a failure comes back through draftsProvider (see the
    // listener in build()).
    _controller.clear();
    ref
        .read(sendQueueProvider.notifier)
        .enqueue(id, body: body, replyTo: ref.read(replyingToProvider));
  }

  Future<void> _saveEdit(Message editing, String body) async {
    setState(() => _sending = true);
    final result = await ref
        .read(messagesProvider.notifier)
        .editMessage(editing, body);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case Ok():
        // Cleared only on success, so nothing a member typed is lost.
        _controller.clear();
        ref.read(editingProvider.notifier).clear();
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  /// Picks one or more images (the paperclip's photo grid: recent photos,
  /// the camera tile, or "Gallery"), previews them with a caption box, and
  /// sends them -- the caption goes with the first one, the rest with none,
  /// one message per photo. Backing out of either step sends nothing.
  Future<void> _attach() async {
    if (_sending) return;
    final picked = await showAttachmentSheet(context);
    if (picked.images.isEmpty || !mounted) return;
    final reviewed = await showAttachmentPreview(
      context,
      images: picked.images,
      caption: _controller.text,
    );
    if (reviewed == null || reviewed.images.isEmpty || !mounted) return;
    setState(() => _sending = true);
    final result = await ref
        .read(messagesProvider.notifier)
        .sendImages(reviewed.images, body: reviewed.caption);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case Ok():
        _controller.clear();
        if (picked.dropped > 0) {
          showSisNotice(
            context,
            'Only the first 10 photos were sent.',
            isError: false,
          );
        }
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _conversationId;
    // A group left or been removed from: read-only, nothing more to write.
    // Checked before the listeners below register at all -- there is
    // nothing left for any of them to restore into a box that cannot send.
    final hasLeft =
        id != null &&
        (ref.watch(conversationListProvider).value ?? const [])
                .where((c) => c.id == id)
                .firstOrNull
                ?.hasLeft ==
            true;
    final isSystem =
        id != null &&
        (ref.watch(conversationListProvider).value ?? const [])
                .where((c) => c.id == id)
                .firstOrNull
                ?.isSystem ==
            true;
    if (hasLeft || isSystem) {
      return Container(
        key: ValueKey(isSystem ? 'composer-system' : 'composer-left'),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + _composerBottomInset(context),
        ),
        child: Text(
          isSystem
              ? 'Only SIS can post here'
              : "You're no longer in this group",
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final replying = ref.watch(replyingToProvider);
    final editing = ref.watch(editingProvider);
    ref.listen(editingProvider, (previous, next) {
      if (next != null && previous?.id != next.id) {
        _controller.text = next.body;
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      } else if (next == null && previous != null) {
        // Edit mode is never a draft: whatever was drafted before editing
        // began (nothing, if the box was empty) comes back now, not the
        // edited text.
        final draft = id == null
            ? const Draft()
            : ref.read(draftsProvider.notifier).draftFor(id);
        _applyDraft(draft);
      }
    });
    if (id != null) {
      // The member started or cleared a reply outside this composer (a
      // message's own reply action) -- kept in the draft too, live.
      // [ReplyingTo] itself watches openConversationProvider and resets to
      // null on ANY change to it, including this composer's own conversation
      // closing (back) -- not just an explicit clear. Once that has
      // happened this listener's `id` is no longer the open conversation, so
      // this null is not the member clearing anything and must not
      // overwrite the reply target already saved in the draft.
      ref.listen(replyingToProvider, (previous, next) {
        if (_applyingDraft ||
            ref.read(editingProvider) != null ||
            ref.read(openConversationProvider) != id) {
          return;
        }
        // A reply the member started (swipe or menu) opens the keyboard;
        // draft restores set _applyingDraft and returned above.
        if (next != null && next.id != previous?.id) _focus.requestFocus();
        _applyingDraft = true;
        ref.read(draftsProvider.notifier).setReply(id, next);
        _applyingDraft = false;
      });
      // A queued send for this conversation failed while the composer was
      // already open: its bodies are already prepended into the draft
      // (DraftsController.restoreFailure) -- reflect that here and show
      // the notice once. [initState] covers the same failure resolving
      // before this composer existed; both read the same draft entry, so
      // this is the composer's one restore path, not two.
      ref.listen(draftsProvider.select((m) => m[id]), (previous, next) {
        if (_applyingDraft) return;
        _restoreDraft(id);
      });
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        6,
        8,
        10,
        _isIos(context) ? 4 + _composerBottomInset(context) : 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editing != null)
            _EditBar(editing)
          else if (replying != null)
            _ReplyBar(replying),
          Row(
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
                  focusNode: _focus,
                  // Messages, captions and edits all start with a capital; the
                  // keyboard's own setting still decides (nothing is forced).
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  // A non-null onEditingComplete replaces Flutter's default,
                  // which unfocuses the field on the send action and so
                  // closes the keyboard.
                  onEditingComplete: _send,
                  // Throttled, and silent when the member does not share typing.
                  onChanged: (text) {
                    if (text.isNotEmpty) {
                      ref.read(typingProvider.notifier).signalTyping();
                    }
                    if (id == null || _applyingDraft) return;
                    if (ref.read(editingProvider) != null) return;
                    ref.read(draftsProvider.notifier).setText(id, text);
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
                onPressed: _sending
                    ? null
                    : () {
                        _send();
                        _focus.requestFocus();
                      },
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the composer is answering, with a way to stop.
class _ReplyBar extends ConsumerWidget {
  const _ReplyBar(this.message);

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    final name = message.senderId == me
        ? 'You'
        : (ref.watch(yourPeopleProvider).value ?? const [])
                  .where((m) => m.userId == message.senderId)
                  .firstOrNull
                  ?.displayName ??
              'Member';
    return Container(
      key: const ValueKey('reply-bar'),
      margin: const EdgeInsets.fromLTRB(10, 0, 0, 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $name',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  quoteText(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('reply-cancel'),
            tooltip: 'Cancel reply',
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(replyingToProvider.notifier).clear(),
          ),
        ],
      ),
    );
  }
}

/// What the composer is editing, with a way to stop.
class _EditBar extends ConsumerWidget {
  const _EditBar(this.message);

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      key: const ValueKey('edit-bar'),
      margin: const EdgeInsets.fromLTRB(10, 0, 0, 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  quoteText(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('edit-cancel'),
            tooltip: 'Cancel edit',
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(editingProvider.notifier).clear(),
          ),
        ],
      ),
    );
  }
}

/// A quoted message in one line: its text, "Photo", or what became of it.
String quoteText(Message? message) => switch (message) {
  null => 'Original message',
  Message(isDeleted: true) => 'This message was deleted',
  Message(:final body) when body.isNotEmpty => body,
  Message(hasAttachment: true) => '📷 Photo',
  _ => 'Message',
};

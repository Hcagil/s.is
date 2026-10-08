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
  final _attachKey = GlobalKey();

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
      showSisNotice(
        context,
        _videoFailureText(context, failure),
        isError: true,
      );
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

  /// Picks one phone contact and sends it as a contact card. Backing out of
  /// the picker sends nothing; a refused send shows its reason.
  Future<void> _sendContact() async {
    final picked = await showContactPicker(context);
    if (picked == null || !mounted) return;
    final result = await ref
        .read(messagesProvider.notifier)
        .sendContact(picked);
    if (result case Err(:final failure) when mounted) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  /// Opens the Share location page; the place it returns is queued like a
  /// message, so the card shows at once and goes out by itself, waiting
  /// offline. Backing out sends nothing.
  Future<void> _sendLocation() async {
    final id = _conversationId;
    if (id == null) return;
    final place = await showLocationShare(context);
    if (place == null || !mounted) return;
    ref.read(sendQueueProvider.notifier).enqueueLocation(id, place);
  }

  /// Opens the phone's file chooser (several files allowed) and queues each
  /// picked file like a message: the pending bubble shows at once and the
  /// file sends by itself, waiting offline. Files over 50 MB are skipped with
  /// one notice. Backing out sends nothing.
  Future<void> _sendFiles() async {
    final id = _conversationId;
    if (id == null) return;
    final pick = await ref.read(deviceFilesProvider).pick();
    if (!mounted) return;
    final queue = ref.read(sendQueueProvider.notifier);
    // Only the first file answers the reply target; enqueueFile spends it.
    for (final file in pick.files) {
      queue.enqueueFile(id, file, replyTo: ref.read(replyingToProvider));
    }
    if (pick.tooBig > 0) {
      showSisNotice(
        context,
        AppLocalizations.of(context).fileTooBig(pick.tooBig),
        isError: true,
      );
    }
  }

  /// Opens the phone's video chooser (several allowed), shows the picked
  /// videos on the review page, and queues each selected one: the bubble shows
  /// at once, the video is shrunk and sent by itself, waiting offline. Videos
  /// over 5 minutes are skipped with one notice. Backing out sends nothing and
  /// the picked copies are deleted. With the in-app grid (iPhone) the ticked
  /// videos are the selection; otherwise the phone's own chooser and the
  /// review page are used.
  Future<void> _sendVideos() async {
    final id = _conversationId;
    if (id == null) return;
    final device = ref.read(deviceVideosProvider);
    // The in-app grid (iPhone) is itself the selection and has already
    // copied the ticked videos; the phone's picker needs the review page.
    var viaGrid = false;
    var pick = const VideoPick();
    if (ref.read(videoGridEnabledProvider)) {
      final grid = await showVideoGrid(context);
      if (!mounted) {
        if (grid != null && !grid.phonePicker) {
          for (final video in grid.pick.videos) {
            await device.discard(video);
          }
        }
        return;
      }
      if (grid == null) return;
      if (!grid.phonePicker) {
        pick = grid.pick;
        viaGrid = true;
      }
    }
    if (!viaGrid) pick = await device.pick();
    if (!mounted) {
      for (final video in pick.videos) {
        await device.discard(video);
      }
      return;
    }
    if (pick.tooLong > 0) {
      showSisNotice(
        context,
        AppLocalizations.of(context).videoTooLong(pick.tooLong),
        isError: true,
      );
    }
    if (pick.videos.isEmpty) return;
    final chosen = viaGrid
        ? pick.videos
        : await showVideoReview(context, pick.videos) ?? const [];
    for (final video in pick.videos) {
      if (!chosen.contains(video)) await device.discard(video);
    }
    if (!mounted) {
      for (final video in chosen) {
        await device.discard(video);
      }
      return;
    }
    final queue = ref.read(sendQueueProvider.notifier);
    for (final video in chosen) {
      queue.enqueueVideo(id, video, replyTo: ref.read(replyingToProvider));
    }
  }

  /// Picks one or more images (the paperclip's photo grid: recent photos,
  /// the camera tile, or "Gallery"), previews them with a caption box, and
  /// sends them -- the caption goes with the first one, the rest with none,
  /// one message per photo. Backing out of either step sends nothing.
  Future<void> _attach() async {
    if (_sending) return;
    final box = _attachKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final choice = await showAttachMenu(context, anchor: anchor);
    if (!mounted) return;
    if (choice == 'poll') return _sendPoll();
    if (choice == 'contact') return _sendContact();
    if (choice == 'location') return _sendLocation();
    if (choice == 'file') return _sendFiles();
    if (choice == 'video') return _sendVideos();
    if (choice != 'photo') return;
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
            AppLocalizations.of(context).composerPhotoLimit,
            isError: false,
          );
        }
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  /// Opens the new-poll page and sends what it returns; backing out sends
  /// nothing.
  Future<void> _sendPoll() async {
    final draft = await Navigator.of(context).push<PollDraft>(
      MaterialPageRoute(builder: (_) => const PollCreatePage()),
    );
    if (draft == null || !mounted) return;
    final result = await ref.read(messagesProvider.notifier).sendPoll(draft);
    if (!mounted) return;
    if (result case Err(:final failure)) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
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
          isSystem ? l.composerReadOnlySystem : l.composerLeftGroup,
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
              KeyedSubtree(
                key: _attachKey,
                child: IconButton(
                  key: const ValueKey('composer-attach'),
                  onPressed: _sending ? null : _attach,
                  icon: const Icon(Icons.attach_file_rounded),
                  tooltip: l.composerSendPhoto,
                ),
              ),
              GreyOption(
                name: 'c_btn',
                child: const _GreyGlyph(Icons.emoji_emotions_outlined),
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
                  decoration: InputDecoration(
                    hintText: l.commonMessage,
                    counterText: '',
                  ),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) =>
                    (value.text.isNotEmpty || editing != null)
                    ? const SizedBox.shrink()
                    : GreyOption(
                        name: 'v_dict',
                        child: const _GreyGlyph(Icons.keyboard_voice_outlined),
                      ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) =>
                    (value.text.isNotEmpty || editing != null)
                    ? IconButton.filled(
                        key: const ValueKey('composer-send'),
                        onPressed: _sending
                            ? null
                            : () {
                                _send();
                                _focus.requestFocus();
                              },
                        icon: const Icon(Icons.arrow_upward_rounded),
                      )
                    : GreyOption(name: 'v_rec', child: const _GreyRecGlyph()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A greyed composer icon: no tap target and no handler; the surrounding
/// GreyOption supplies the dimmed look.
class _GreyGlyph extends StatelessWidget {
  const _GreyGlyph(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}

/// The greyed mic: the filled send button's look (brand gradient disc),
/// with no handler.
class _GreyRecGlyph extends StatelessWidget {
  const _GreyRecGlyph();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 48,
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SisBrand.of(context).gradient,
        ),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.mic_rounded, color: Colors.white),
        ),
      ),
    ),
  );
}

/// What the composer is answering, with a way to stop.
class _ReplyBar extends ConsumerWidget {
  const _ReplyBar(this.message);

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final me = ref.watch(currentUserIdProvider);
    final name = message.senderId == me
        ? l.commonYou
        : (ref.watch(yourPeopleProvider).value ?? const [])
                  .where((m) => m.userId == message.senderId)
                  .firstOrNull
                  ?.displayName ??
              l.commonMember;
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
                  l.composerReplyingTo(name),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  quoteText(l, message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('reply-cancel'),
            tooltip: l.composerCancelReply,
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
    final l = AppLocalizations.of(context);
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
                  l.composerEditing,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  quoteText(l, message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('edit-cancel'),
            tooltip: l.composerCancelEdit,
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(editingProvider.notifier).clear(),
          ),
        ],
      ),
    );
  }
}

/// A quoted message in one line: its text, "Photo", or what became of it.
String quoteText(AppLocalizations l, Message? message) => switch (message) {
  null => l.quoteOriginal,
  Message(isDeleted: true) => l.quoteDeleted,
  Message(:final body) when body.isNotEmpty => body,
  Message(:final file?) => file.isVideo ? videoPreview : file.name,
  Message(hasAttachment: true) => l.quotePhoto,
  _ => l.commonMessage,
};

/// The words for a failed send; the video failures are translated here, any
/// other failure keeps its own message.
String _videoFailureText(BuildContext context, Failure failure) {
  final l = AppLocalizations.of(context);
  return switch (failure) {
    VideoTooBigFailure() => l.videoTooBig,
    VideoFailedFailure() => l.videoFailed,
    _ => failure.message,
  };
}

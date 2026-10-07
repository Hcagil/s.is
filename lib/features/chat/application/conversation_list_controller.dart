part of 'chat_controllers.dart';

final conversationListProvider =
    AsyncNotifierProvider<ConversationListController, List<Conversation>>(
      ConversationListController.new,
      retry: _never,
    );

/// The conversation list. Failures surface as [AsyncError] carrying the
/// [Failure], so the screen always has a reason to show.
class ConversationListController extends AsyncNotifier<List<Conversation>> {
  /// Batches a save after a live update so a burst of incoming messages
  /// costs one disk write, not one per message.
  Timer? _snapshotDebounce;

  /// Bumped by every build and every [catchUp], so a Realtime join that lands
  /// after a newer one started is dropped (ref.mounted cannot tell).
  int _gen = 0;

  /// The current all-conversations Realtime subscription.
  StreamSubscription<Message>? _live;

  /// Kept current by a Realtime subscription to every conversation the member
  /// belongs to. Subscribing happens BEFORE the first read and anything that
  /// arrives in between is buffered, the same way the message screen does it,
  /// so a message sent during the load is not lost.
  ///
  /// A subscription that cannot be established does not fail the list: the
  /// list still loads, and returning from a conversation refreshes it.
  @override
  Future<List<Conversation>> build() async {
    // Rebuilt from scratch for each account: never the last one's list.
    ref.watch(currentUserIdProvider);
    final ownerId = ref.read(currentUserIdProvider);
    final gen = ++_gen;
    ref.onDispose(() => unawaited(_live?.cancel()));
    // Riverpod 3 ALWAYS carries a previous value into a new AsyncLoading (or
    // a later AsyncError) via copyWithPrevious -- including one assigned
    // explicitly, right here, by this very build(): `state =
    // const AsyncLoading()` would still answer .value with the last owner's
    // rows, because copyWithPrevious merges with whatever state already held
    // (set by the framework itself before build() even starts, from the
    // previous owner's last settled list). AsyncData is the one exception --
    // AsyncData.copyWithPrevious always returns itself, ignoring what came
    // before -- so assigning a clean, empty AsyncData first launders the
    // slate, and the AsyncLoading assigned right after it only ever merges
    // with THAT (empty) value, never the old owner's. Both assignments land
    // before build()'s first await, so neither is ever observed on its own;
    // only the second is what the very first listener (an existing
    // subscriber, or a new one with fireImmediately) can ever see -- an
    // ordinary loading state whose .value is empty, not the previous owner's.
    // This is the one place every owner change routes through (the provider
    // lives for the app's whole run and only rebuilds when
    // currentUserIdProvider itself changes -- see its doc), so doing it here
    // makes it structurally impossible for a stale value to reach `_apply`,
    // `markRead`, `_saveCurrentIfData`, or an outside reader of `.value`
    // (conversation_list.dart, profile_pages.dart, ...): they all see an
    // AsyncLoading whose .value is the empty list (hasValue is true), not
    // the previous owner's rows, until THIS build's own settled data (the
    // disk cache below, or the server) lands.
    state = const AsyncData(<Conversation>[]);
    state = const AsyncLoading();
    // True for as long as THIS build is the current one. ref.mounted alone
    // cannot tell that apart from the Notifier being disposed outright: a
    // rebuild (e.g. an account change) reuses the same Notifier, so
    // ref.mounted stays true for a build already replaced by a newer one.
    // Registered synchronously, before the cache read below, so it is set
    // the moment this build is replaced OR the Notifier is disposed -- and
    // also guards the cache-restore state assignment right below.
    var alive = true;
    ref.onDispose(() => alive = false);
    // The store provider is unoverridden in most tests (it throws
    // UnimplementedError the moment it's read, not just on a failed disk
    // op), so this must be guarded the same as any other best-effort read.
    List<Conversation>? cached;
    if (ownerId != null) {
      try {
        cached = await ref.read(chatListSnapshotStoreProvider).load(ownerId);
      } catch (_) {
        cached = null;
      }
    }
    if (cached != null && alive && ref.mounted) state = AsyncData(cached);
    final buffered = <Message>[];
    var loaded = false;
    ref.onDispose(() => _snapshotDebounce?.cancel());
    // The Realtime join can take up to 15s and must never gate the list: it
    // starts alongside the fetch below instead of being awaited first.
    // Nothing can arrive before the join itself completes, and the
    // StreamController buffers anything that lands before `.listen` runs
    // here (see _inserts), so whichever of the join or the load finishes
    // first, nothing sent during the race is lost.
    unawaited(
      ref
          .read(chatRepositoryProvider)
          .incomingAll()
          .then((opened) {
            if (opened case Ok(:final value)) {
              if (!alive || gen != _gen) {
                // This build was replaced or disposed while the join was
                // still out: listen only long enough to cancel, which tears
                // the channel down through the same onCancel -> leaveChannel
                // path a normal cancel uses, rather than leaving a live
                // subscription nothing owns.
                unawaited(value.listen((_) {}).cancel());
                return;
              }
              final sub = value.listen(
                (message) {
                  if (!loaded) {
                    buffered.add(message);
                  } else {
                    _apply(message);
                  }
                },
                // A dropped subscription only stops live updates; the
                // re-read on returning from a conversation still keeps the
                // list current.
                onError: (Object _) {},
              );
              _live = sub;
              ref.onDispose(sub.cancel);
            }
          })
          .catchError((Object e, StackTrace st) {
            // A join that throws before it can even answer Err (e.g.
            // _client.channel() itself) only costs the live part, same as
            // an Err from incomingAll() and a dropped subscription later --
            // the list still loads and refresh() still works.
            log('$e', name: 'sis.chat', error: e, stackTrace: st);
          }),
    );
    List<Conversation> list;
    try {
      list = await _load();
      loaded = true;
      var unknown = false;
      for (final message in buffered) {
        if (message.isDeleted || message.editedAt != null) {
          unknown = true; // a deletion or edit during the load: read again
          continue;
        }
        final next = _withMessage(list, message);
        if (next == null) {
          unknown = true;
        } else {
          list = next;
        }
      }
      // A buffered message for a conversation the first read did not contain
      // means one was started during the load: read again rather than drop it.
      if (unknown) list = await _load();
      _reportUnreadDelivered(list);
    } catch (e) {
      // A stored list already shown stays on every load error but a refusal
      // (DeniedFailure; the session controller handles a revoked member):
      // the member's own data beats an error box, and a small notice says it
      // is old.
      if (cached == null || e is DeniedFailure) rethrow;
      loaded = true;
      list = cached;
      return list;
    }
    if (ownerId != null && alive) _saveSnapshot(ownerId, list);
    return list;
  }

  /// Fire-and-forget: the store itself never throws once read (see
  /// ChatListSnapshotStore's contract), but reading the provider does, when
  /// nothing overrides it (most tests) -- guarded the same as [build]'s read.
  void _saveSnapshot(String ownerId, List<Conversation> conversations) {
    try {
      unawaited(
        ref.read(chatListSnapshotStoreProvider).save(ownerId, conversations),
      );
    } catch (_) {
      // No store configured: nothing to save to.
    }
  }

  /// Moves [message] into its conversation's preview. A message for a
  /// conversation the list has never seen means someone started one with
  /// this member, so the list is re-read rather than guessed at.
  void _apply(Message message) {
    final current = state.value;
    if (current == null) return;
    // A deletion can change which message a conversation previews, and the
    // list does not hold the one before it: read again.
    if (message.isDeleted) {
      reloadQuietly();
      return;
    }
    if (message.editedAt != null) {
      final index = current.indexWhere((c) => c.id == message.conversationId);
      // Only when the edited message is still the previewed one -- an edit
      // to an older message further up the conversation changes nothing
      // shown in the list.
      final previewedAt = index >= 0 ? current[index].lastMessageAt : null;
      if (index >= 0 &&
          (previewedAt?.isAtSameMomentAs(message.createdAt) ?? false)) {
        state = AsyncData([
          for (var i = 0; i < current.length; i++)
            if (i == index) current[i].withPreview(message) else current[i],
        ]);
        _scheduleSnapshotSave();
      }
      return;
    }
    final me = switch (ref.read(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    if (message.senderId != me) {
      _reportDelivered(message.conversationId, message.createdAt);
    }
    final next = _withMessage(current, message);
    if (next == null) {
      reloadQuietly();
    } else {
      state = AsyncData(next);
      _scheduleSnapshotSave();
    }
  }

  /// [list] with [message] as its conversation's preview, newest first; null
  /// when the conversation is not in [list]. An older message never replaces
  /// a newer preview, so a late or repeated delivery is harmless -- and is
  /// never counted as unread twice.
  List<Conversation>? _withMessage(List<Conversation> list, Message message) {
    final index = list.indexWhere((c) => c.id == message.conversationId);
    if (index < 0) return null;
    final existing = list[index];
    final me = switch (ref.read(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    // A sender the list does not know yet (someone added to this group since
    // the list was read) cannot be named or coloured: null makes the caller
    // read the list again, as for an unknown conversation.
    if (existing.isGroup &&
        !existing.isSystem &&
        message.senderId != me &&
        !existing.senders.containsKey(message.senderId)) {
      return null;
    }
    final at = existing.lastMessageAt;
    // Not newer than the current preview -- a late delivery, or the same
    // message delivered twice -- leaves the list exactly as it was. Using
    // "older" here instead would let a duplicate move its conversation above
    // one with a genuinely newer message.
    if (at != null && !message.createdAt.isAfter(at)) return list;
    final updated = [...list]..removeAt(index);
    // Unread: someone else's message, in a conversation not on screen.
    final counts =
        message.senderId != me &&
        ref.read(openConversationProvider) != message.conversationId;
    return [existing.withPreview(message, counts: counts), ...updated];
  }

  /// Marks [conversationId] read on the server, then clears its count here.
  /// A failure leaves the count as it was: better a stale badge than a
  /// conversation that looks read and is not.
  ///
  /// Skips the local update (and therefore the debounced save) when state is
  /// still loading -- i.e. carrying over a value from a previous build/owner.
  Future<void> markRead(String conversationId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .markRead(conversationId);
    // Checked before touching state: the list can be disposed while the call
    // is in flight, and reading state then throws.
    if (result is! Ok || !ref.mounted || state.isLoading) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final c in current) c.id == conversationId ? c.read() : c,
    ]);
    _scheduleSnapshotSave();
  }

  Future<List<Conversation>> _load() async {
    final list = switch (await ref
        .read(chatRepositoryProvider)
        .conversations()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    return list;
  }

  /// Unread here means received on this device: report it delivered, once per
  /// conversation per load.
  void _reportUnreadDelivered(List<Conversation> list) {
    for (final c in list) {
      if (c.unread > 0) _reportDelivered(c.id);
    }
  }

  /// Tells the server this device has received [conversationId]'s messages
  /// (up to [upTo]) so the sender's ticks reach two grey, even while the chat
  /// is closed. Fire-and-forget: a failure only delays a tick.
  void _reportDelivered(String conversationId, [DateTime? upTo]) {
    unawaited(
      ref
          .read(chatRepositoryProvider)
          .markDelivered(conversationId, upTo: upTo),
    );
  }

  Future<void> refresh() async {
    final ownerId = ref.read(currentUserIdProvider);
    final shown = state.asData?.value;
    state = const AsyncLoading();
    final next = await AsyncValue.guard(_load);
    if (!ref.mounted) return;
    if (ref.read(currentUserIdProvider) != ownerId) return;
    // A list already on screen stays on every failure but a refusal; the small
    // notice says it is old. With nothing on screen the error box reports it.
    if (next is AsyncError && shown != null && next.error is! DeniedFailure) {
      state = AsyncData(shown);
      return;
    }
    if (next case AsyncData(:final value)) _reportUnreadDelivered(value);
    state = next;
    _saveCurrentIfData();
  }

  /// The app is visible again after being backgrounded, where the Realtime
  /// connection dies and nothing sent meanwhile is delivered: re-read the
  /// list at once, then join again and re-read once more to close the gap
  /// the join leaves. Skipped while a build is still loading (it is fresh).
  Future<void> catchUp() async {
    if (state.isLoading || !ref.mounted) return;
    final gen = ++_gen;
    final old = _live;
    _live = null;
    if (old != null) unawaited(old.cancel());
    await reloadQuietly();
    final opened = await ref.read(chatRepositoryProvider).incomingAll();
    if (opened is! Ok<Stream<Message>>) return;
    if (gen != _gen || !ref.mounted) {
      unawaited(opened.value.listen((_) {}).cancel());
      return;
    }
    _live = opened.value.listen(_apply, onError: (Object _) {});
    // ponytail: a message inserted during this last read can be missed; the
    // next resume or returning from a chat reads again.
    await reloadQuietly();
  }

  /// Re-reads without showing a spinner: the list on screen stays while the
  /// new one loads. A failed background re-read keeps the list as it was
  /// rather than replacing something correct with an error the member did
  /// not ask for; the small notice says it is old, and only while a list is
  /// on screen.
  Future<void> reloadQuietly() async {
    final ownerId = ref.read(currentUserIdProvider);
    final next = await AsyncValue.guard(_load);
    if (!ref.mounted) return;
    if (ref.read(currentUserIdProvider) != ownerId) return;
    if (next is AsyncData<List<Conversation>>) {
      _reportUnreadDelivered(next.value);
      state = next;
    }
    _saveCurrentIfData();
  }

  /// A full load just finished (explicit [refresh] or a quiet re-read):
  /// saved right away, unlike a single live update, which is debounced by
  /// [_scheduleSnapshotSave] instead.
  ///
  /// Saves only when the session is settled (Allowed) AND this build's state
  /// is settled (AsyncData with isLoading=false), not carrying over a value
  /// from a previous build/owner.
  void _saveCurrentIfData() {
    if (ref.read(sessionControllerProvider).value is! Allowed) return;
    final ownerId = ref.read(currentUserIdProvider);
    final current = state;
    if (ownerId != null &&
        current is AsyncData<List<Conversation>> &&
        !current.isLoading) {
      _saveSnapshot(ownerId, current.value);
    }
  }

  /// Batches a save after a live update so a burst of incoming messages
  /// costs one disk write, not one per message. Checks the store is
  /// actually configured BEFORE scheduling: with nothing to save to (most
  /// tests, which never override [chatListSnapshotStoreProvider]) this must
  /// not leave a bare Timer running past the caller's own lifetime.
  void _scheduleSnapshotSave() {
    try {
      ref.read(chatListSnapshotStoreProvider);
    } catch (_) {
      return;
    }
    _snapshotDebounce?.cancel();
    _snapshotDebounce = Timer(const Duration(seconds: 2), _saveCurrentIfData);
  }

  /// Opens the 1:1 conversation with [otherUserId], creating it if needed.
  Future<Result<String>> startWith(String otherUserId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .startDirectConversation(otherUserId);
    if (result is Ok<String>) {
      await refresh();
    }
    return result;
  }

  /// Creates a group and shows it in the list.
  Future<Result<String>> startGroup({
    required String title,
    required List<String> memberIds,
  }) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .startGroupConversation(title: title, memberIds: memberIds);
    if (result is Ok<String>) {
      await refresh();
    }
    return result;
  }

  /// Sets or clears [conversationId]'s picture; any member may call this.
  /// Re-reads the list quietly on success, same as [markRead].
  Future<Result<void>> setGroupAvatar(
    String conversationId,
    PickedImage? image,
  ) async {
    final previous = (state.value ?? const <Conversation>[])
        .where((c) => c.id == conversationId)
        .firstOrNull
        ?.avatarPath;
    final result = await ref
        .read(chatRepositoryProvider)
        .setGroupAvatar(conversationId, image, previousPath: previous);
    if (result is Ok && ref.mounted) {
      await reloadQuietly();
    }
    return result;
  }

  /// [conversationId]'s settings as the list shows them now, or null when it
  /// is not listed.
  GroupSettings? settingsOf(String conversationId) =>
      (state.value ?? const <Conversation>[])
          .where((c) => c.id == conversationId)
          .firstOrNull
          ?.settings;

  /// Archives or unarchives [conversationId] for the signed-in member. The
  /// list changes at once (the swipe never waits on the network); a refusal
  /// puts the chat back and returns the [Err]. An archived chat stays
  /// archived when new messages arrive: [Conversation.withPreview] keeps the
  /// flag.
  Future<Result<void>> setArchived(String conversationId, bool archived) async {
    void mark(bool value) {
      final list = state.value;
      if (list == null) return;
      state = AsyncData([
        for (final c in list)
          if (c.id == conversationId) c.withArchived(value) else c,
      ]);
      _scheduleSnapshotSave();
    }

    mark(archived);
    final result = await ref
        .read(chatArchiveRepositoryProvider)
        .setArchived(conversationId, archived);
    if (result is Err && ref.mounted) mark(!archived);
    return result;
  }

  /// Shows [next] as [conversationId]'s settings at once, without a server
  /// call: a switch flips the same frame. The list is re-read from the
  /// server by the usual refreshes.
  void applySettings(String conversationId, GroupSettings next) {
    final list = state.value;
    if (list == null) return;
    state = AsyncData([
      for (final c in list)
        if (c.id == conversationId) c.withSettings(next) else c,
    ]);
    _scheduleSnapshotSave();
  }
}

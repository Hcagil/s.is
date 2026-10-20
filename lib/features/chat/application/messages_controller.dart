part of 'chat_controllers.dart';

final messagesProvider =
    AsyncNotifierProvider<MessagesController, List<Message>>(
      MessagesController.new,
      retry: _never,
    );

/// True while an older page of the open conversation is being read: the
/// screen shows a small loader at the top of the list meanwhile.
final olderLoadingProvider = NotifierProvider<OlderLoading, bool>(
  OlderLoading.new,
);

class OlderLoading extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(openConversationProvider);
    return false;
  }

  void set(bool loading) => state = loading;
}

/// Messages of the open conversation, oldest first.
///
/// The initial read and the Realtime stream are merged by message id.
/// Sending a text message (or a photo, since v0.9) is optimistic: a pending
/// bubble shows the moment [MessagesController.send] is called, before the
/// server has answered, and several sent in quick succession queue behind
/// one another so the server sees them -- and times them -- in the order
/// they were typed (see [MessagesController.send] and
/// [MessagesController._drain]). The server's own row then replaces the
/// pending bubble in place, whichever answer arrives first -- the POST
/// response or the Realtime echo of the same insert -- so the sender's own
/// message appears exactly once, never twice.
class MessagesController extends AsyncNotifier<List<Message>> {
  /// Whether the shown list is a [jumpToAround] snapshot rather than the
  /// live, newest window.
  bool _jumped = false;

  /// Counts this member's own optimistic deletes and hides, so a background
  /// re-read that began before one cannot undo it (see _verify).
  int _ownEdits = 0;

  /// True while [jumpToAround] has replaced the shown list with an old
  /// window; false once live (including before any jump at all).
  bool get isJumped => _jumped;

  /// Set by [returnToLive]: the next build carries nothing over from the
  /// jumped window (it is not contiguous with the live page).
  bool _fromJump = false;

  /// The anchor id of the most recent [jumpToAround] call -- an answer for
  /// any earlier one is dropped, even if it arrives later.
  String? _requestedAnchorId;

  /// The conversation the current state belongs to. Riverpod 3 always carries
  /// the previous value into a reload, so a rebuild for a different chat would
  /// otherwise answer `.value` with the chat just left.
  String? _stateFor;

  /// Bumped by every build: an answer that started under an older build is
  /// dropped.
  int _epoch = 0;

  /// True once the oldest message of the conversation is loaded (a read that
  /// came back shorter than [messagePageSize]).
  bool _noOlder = false;
  bool _loadingOlder = false;
  bool _loadingNewer = false;
  int _catchUpRetries = 0;
  static const _maxCatchUpRetries = 5;
  DateTime _verifiedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The live list shown just before the first [jumpToAround] of a jump run:
  /// [returnToLive] shows it at once, without waiting for the network.
  List<Message>? _liveBeforeJump;

  /// Photo messages whose preview was already asked for in this build, so a
  /// message that has none is not asked again and again.
  final _previewAsked = <String>{};

  /// Whether scrolling up may still find older messages.
  bool get hasOlder => !_noOlder;

  /// The newest messages of chats left this run, shown at once when one is
  /// opened again while the read is out. Cleared on an account change.
  final _memory = <String, List<Message>>{};
  String? _memoryOwner;

  void _remember(String id, List<Message>? list) {
    if (list == null) return;
    final kept = [
      for (final m in list)
        if (!m.isPending) m,
    ];
    _memory.remove(id);
    if (kept.isEmpty) return;
    // Only the newest page is kept: that is what the next open reads first.
    _memory[id] = kept.length > messagePageSize
        ? kept.sublist(kept.length - messagePageSize)
        : kept;
    if (_memory.length > 8) _memory.remove(_memory.keys.first);
  }

  @override
  Future<List<Message>> build() async {
    final owner = ref.watch(currentUserIdProvider);
    if (owner != _memoryOwner) {
      _memory.clear();
      _memoryOwner = owner;
      _stateFor = null;
    }
    final wasJumped = _jumped;
    _jumped = false;
    final conversationId = ref.watch(openConversationProvider);
    if (_stateFor != conversationId) {
      final left = _stateFor;
      if (left != null && !wasJumped) _remember(left, state.value);
      _stateFor = conversationId;
      // Launder the carried value, as ConversationListController.build does:
      // the AsyncData is replaced by AsyncLoading before the first await, so
      // only a loading state is ever observed -- never the last chat's
      // messages. What it holds is this chat's own remembered list (empty
      // when none), which the screen shows while the read is out. (A
      // same-chat catchUp keeps its value on purpose.)
      state = AsyncData(_memory[conversationId] ?? const <Message>[]);
      state = const AsyncLoading();
    }
    if (conversationId == null) return const [];
    _epoch++;
    if (_loadingOlder) {
      // The page in flight belongs to the replaced build, which will not clear
      // the loader; a provider may not be written during build, so a turn later.
      Future.microtask(() {
        if (ref.mounted) ref.read(olderLoadingProvider.notifier).set(false);
      });
    }
    _loadingOlder = false;
    _loadingNewer = false;
    _liveBeforeJump = null;
    _noOlder = false;
    _previewAsked.clear();
    // What this chat already shows (its remembered newest page, or what a
    // catch-up rebuild keeps): previews and older rows outlive the new read.
    final fromJump = wasJumped || _fromJump;
    _fromJump = false;
    // A jumped window is not contiguous with the live page: none of it is
    // carried over (its previews are read again).
    final shownBefore = fromJump
        ? const <Message>[]
        : (state.value ?? const <Message>[]);

    final repo = ref.read(chatRepositoryProvider);
    final buffered = <Message>[];
    var loaded = false;
    StreamSubscription<Message>? sub;
    ref.onDispose(() => unawaited(sub?.cancel()));
    // True while THIS build is current: ref.mounted stays true for a build
    // already replaced by a newer one (a chat switch), onDispose fires for both.
    var alive = true;
    ref.onDispose(() => alive = false);
    void onMessage(Message message) {
      // Strictly this chat's: a row for another conversation is never shown.
      if (message.conversationId != conversationId) return;
      _persist([message]);
      if (!loaded) {
        buffered.add(message);
        return;
      }
      if (message.isDeleted) {
        _deleted(message);
        return;
      }
      // An admin reply changes after it is sent (a confirmation card is answered): same in-place replacement as an edit.
      if (message.editedAt != null ||
          (message.adminMsg != null &&
              (state.value?.any((m) => m.id == message.id) ?? false))) {
        _edited(message);
        return;
      }
      _append(message);
      // Open on screen means read; tell the server so the count stays zero.
      // Only while the app is visible: one that lands while it is hidden is
      // marked by the resume catch-up, when the member actually returns.
      if (!message.isFrom(_me ?? '') && ref.read(appVisibleProvider)) {
        ref.read(conversationListProvider.notifier).markRead(conversationId);
      }
    }

    // Pending sends: queued, in flight, or waiting out a network retry in
    // SendQueueController, which lives independently of this screen. This
    // conversation's list starts with whatever it already holds (below) and
    // is kept current as the queue changes -- see _onQueueChanged -- so a
    // chat reopened mid-send, or opened for the first time while offline
    // sends are still queued, shows them rather than dropping them.
    ref.listen(
      sendQueueProvider.select((m) => m[conversationId] ?? const <Message>[]),
      _onQueueChanged,
    );

    // The join and the read run together, so opening costs the longer of the
    // two, not both. The stream is listened to the moment the join answers;
    // whatever it delivers before the read lands is buffered and merged by
    // id. The read may have been answered before the join took effect on the
    // server, so _verify reads once more after the first paint.
    final joining = repo.incoming(conversationId).then((opened) {
      if (opened case Ok(:final value)) {
        if (alive && ref.mounted) {
          sub = value.listen(onMessage);
        } else {
          unawaited(value.listen((_) {}).cancel());
        }
      }
      return opened;
    });
    // The server read starts now; the stored newest page shows meanwhile (only
    // when this chat shows nothing yet), so a cold open is not blank.
    final reading = repo.messages(conversationId);
    var stored = const <Message>[];
    final store = shownBefore.isEmpty ? _storeOf(ref) : null;
    if (store != null) {
      stored = await store.newest(conversationId, limit: messagePageSize);
      if (alive && ref.mounted && stored.isNotEmpty) {
        final queued = ref.read(sendQueueProvider)[conversationId] ?? const [];
        state = AsyncData([
          ...stored,
          for (final p in queued)
            if (!stored.any((m) => m.id == p.id)) p,
        ]);
      }
    }
    final (joined, read) = await (joining, reading).wait;
    if (!alive) return const []; // replaced or closed mid-open: drop it all
    // A catch-up that cannot reach the server (resume while offline) keeps
    // the list on screen and tries again a little later; only a first open,
    // with nothing to show, is an error. A refusal is never retried.
    final failed = switch ((joined, read)) {
      (Err(:final failure), _) => failure,
      (_, Err(:final failure)) => failure,
      _ => null,
    };
    if (failed != null) {
      // Offline: what is stored counts as something to show.
      final offline = shownBefore.isNotEmpty ? shownBefore : stored;
      if (failed is DeniedFailure ||
          offline.isEmpty ||
          _catchUpRetries >= _maxCatchUpRetries) {
        throw failed;
      }
      _catchUpRetries++;
      unawaited(
        Future<void>.delayed(const Duration(seconds: 5), () {
          if (alive && ref.mounted) ref.invalidateSelf();
        }),
      );
      return offline;
    }
    _catchUpRetries = 0;

    // Both answered Ok here (a failure returned or threw above).
    final value = (read as Ok<List<Message>>).value;
    loaded = true;
    final known = {
      for (final m in shownBefore)
        if (m.attachmentPreview != null) m.id: m.attachmentPreview!,
    };
    final merged = [
      for (final m in value)
        m.attachmentPreview == null && known[m.id] != null
            ? m.withPreview(known[m.id])
            : m,
    ];
    _noOlder = value.length < messagePageSize;
    // Older rows already loaded stay (a scroll position deep in history
    // must not be cut off by a catch-up) -- but only when the new page
    // overlaps them, so the history never has a gap.
    final inPage = {for (final m in value) m.id};
    if (value.isNotEmpty && shownBefore.any((m) => inPage.contains(m.id))) {
      merged.addAll([
        for (final m in shownBefore)
          if (!m.isPending &&
              !inPage.contains(m.id) &&
              m.createdAt.isBefore(value.first.createdAt))
            m,
      ]);
    }
    for (final message in buffered) {
      if (message.conversationId != conversationId) continue;
      final i = merged.indexWhere((m) => m.id == message.id);
      if (i < 0) {
        // An edit or delete of a row older than the page is not for this
        // list: ignored, never added out of place.
        if (value.isNotEmpty &&
            message.createdAt.isBefore(value.first.createdAt)) {
          continue;
        }
        merged.add(message);
      } else if (message.isDeleted || message.editedAt != null) {
        merged[i] = message;
      }
    }
    merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    // Vanished before this screen opened: as if never sent. One that
    // vanishes while open stays long enough to animate away.
    final shown = [
      for (final m in merged)
        if (m.deletion != MessageDeletion.vanished) m,
    ];
    // The server page is the truth: written to the phone in one transaction,
    // stored rows it no longer returns are dropped. Rows that landed live
    // meanwhile (merged above) are part of the page, so they are kept.
    final pageStore = _storeOf(ref);
    if (pageStore != null) {
      unawaited(
        pageStore.reconcilePage(conversationId, [
          for (final m in shown)
            if (value.isNotEmpty &&
                !m.createdAt.isBefore(value.first.createdAt))
              m,
        ], reachedStart: value.length < messagePageSize),
      );
    }
    final pending = ref.read(sendQueueProvider)[conversationId] ?? const [];
    // A later turn, so the list below is already the state when it runs.
    final edits = _ownEdits;
    // Previews (one batched read) start at once, beside the verify read;
    // verify may add rows, so they are looked at again after it.
    unawaited(
      Future(() {
        unawaited(_fillPreviews(conversationId, () => alive));
        return _verify(
          conversationId,
          edits,
          () => alive,
        ).then((_) => _fillPreviews(conversationId, () => alive));
      }),
    );
    // My own photos still in the air (not in the send queue, which holds
    // text only) stay across this re-read, e.g. the one returnToLive
    // starts; a stored copy of one that already landed replaces it.
    final photos = [
      for (final m in state.value ?? const <Message>[])
        if (m.conversationId == conversationId &&
            m.localImage != null &&
            m.attachmentPath == null &&
            !m.sending &&
            !shown.any((s) => s.id == m.id || m.isPendingOf(s)))
          m,
    ];
    return [
      ...shown,
      for (final p in pending)
        if (!shown.any((m) => m.id == p.id)) p,
      ...photos,
    ];
  }

  /// Writes [list] to the on-phone store (best effort, fire and forget). A
  /// legacy `vanished` row leaves the store; a pending send is skipped by it.
  void _persist(Iterable<Message> list) {
    final store = _storeOf(ref);
    if (store == null) return;
    final keep = <Message>[];
    for (final m in list) {
      if (m.deletion == MessageDeletion.vanished) {
        unawaited(store.remove(m.id));
      } else {
        keep.add(m);
      }
    }
    if (keep.isNotEmpty) unawaited(store.upsertAll(keep));
  }

  /// An older page, from the phone, when it provably holds it: no gap between
  /// [oldest] and the page (the chat's contiguous block reaches [oldest]), and
  /// the page is full or the chat's first message is stored. Null means the
  /// server must be asked. `end` is true when nothing older exists.
  Future<({List<Message> rows, bool end})?> _storedOlder(
    String conversationId,
    Message oldest,
  ) async {
    final store = _storeOf(ref);
    if (store == null) return null;
    final sync = await store.syncState(conversationId);
    final from = sync?.contiguousFrom;
    if (sync == null || from == null || from.isAfter(oldest.createdAt)) {
      return null;
    }
    final rows = await store.older(
      conversationId,
      oldest.createdAt,
      limit: messagePageSize,
    );
    if (rows.length >= messagePageSize) {
      return rows.first.createdAt.isBefore(from)
          ? null
          : (rows: rows, end: false);
    }
    return sync.complete ? (rows: rows, end: true) : null;
  }

  /// The window around [anchor] from the phone, when every row of it lies in
  /// the chat's contiguous block; null means the server must be asked.
  Future<List<Message>?> _storedAround(
    String conversationId,
    Message anchor,
  ) async {
    final store = _storeOf(ref);
    if (store == null) return null;
    final sync = await store.syncState(conversationId);
    final from = sync?.contiguousFrom;
    final to = sync?.newestAt;
    if (from == null || to == null) return null;
    const each = 50;
    final rows = await store.around(conversationId, anchor.id, each: each);
    if (rows.isEmpty ||
        rows.first.createdAt.isBefore(from) ||
        rows.last.createdAt.isAfter(to)) {
      return null;
    }
    // A window cut short at contiguousFrom is not covered unless the chat starts there.
    if (!sync!.complete && rows.indexWhere((m) => m.id == anchor.id) < each) {
      return null;
    }
    return rows;
  }

  /// The app is visible again after being backgrounded (or a notification
  /// for this chat was tapped): Realtime died meanwhile and nothing sent
  /// since was delivered, so read the chat again with a fresh subscription
  /// -- build()'s own read, with a fresh subscription. Not while a build is
  /// loading (it is fresh) or a search jump is on screen.
  void catchUp() {
    if (_jumped || state.isLoading) return;
    ref.invalidateSelf();
  }

  /// The member is back at the newest message: a Realtime row missed while the
  /// connection was down (no resume event) is read in by _verify. At most once
  /// per 20 s, never on a search window, never while a build is loading.
  void verifyNewest() {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null ||
        _jumped ||
        state.isLoading ||
        state.hasError ||
        (state.value?.isEmpty ?? true)) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_verifiedAt) < const Duration(seconds: 20)) return;
    _verifiedAt = now;
    final epoch = _epoch;
    bool alive() => ref.mounted && epoch == _epoch;
    unawaited(
      _verify(
        conversationId,
        _ownEdits,
        alive,
      ).then((_) => _fillPreviews(conversationId, alive)),
    );
  }

  /// The first read leaves photo previews out so the first paint never waits
  /// on them; one batched read (the photo messages without one, at most a
  /// page) brings them in right after. One request rather than one per
  /// bubble: a single round trip, and the rows are known already. A failure is
  /// silent -- the photo itself still loads and replaces the blur.
  Future<void> _fillPreviews(
    String conversationId,
    bool Function() alive,
  ) async {
    if (!alive() || !ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    final ids = [
      for (final m in current)
        if (m.attachmentPath != null &&
            m.attachmentPreview == null &&
            _previewAsked.add(m.id))
          m.id,
    ];
    if (ids.isEmpty) return;
    final result = await ref
        .read(chatRepositoryProvider)
        .attachmentPreviews(ids);
    if (!alive() || !ref.mounted) return;
    if (ref.read(openConversationProvider) != conversationId) return;
    final now = state.value;
    if (result is! Ok<Map<String, Uint8List>> || now == null) return;
    final found = result.value;
    if (found.isEmpty) return;
    state = AsyncData([
      for (final m in now)
        m.attachmentPreview == null && found[m.id] != null
            ? m.withPreview(found[m.id])
            : m,
    ]);
  }

  /// Reads the page before the oldest shown message and puts it above, by id.
  /// The screen lists newest-first from the bottom, so rows added past the top
  /// do not move what the member is looking at. Reuses
  /// [ChatRepository.messagesAround] (the oldest shown message as anchor; its
  /// newer half is already shown and is dropped by id). One read at a time;
  /// an answer for a chat that was left or rebuilt meanwhile is dropped, and
  /// a failure is silent -- the next scroll tries again.
  Future<void> loadOlder() async {
    final conversationId = ref.read(openConversationProvider);
    final current = state.value;
    if (conversationId == null ||
        current == null ||
        state.isLoading ||
        _noOlder ||
        _loadingOlder) {
      return;
    }
    final oldest = current.where((m) => !m.isPending).firstOrNull;
    if (oldest == null) return;
    final epoch = _epoch;
    _loadingOlder = true;
    ref.read(olderLoadingProvider.notifier).set(true);
    // The phone answers when it provably holds the page (no gap); else the
    // server.
    final local = await _storedOlder(conversationId, oldest);
    final Result<List<Message>> result = local != null
        ? Ok(local.rows)
        : await ref
              .read(chatRepositoryProvider)
              .messagesAround(conversationId, oldest);
    if (!ref.mounted) return;
    if (epoch != _epoch) return; // rebuilt meanwhile: the new build owns this
    if (local == null && result is Ok<List<Message>>) {
      _persist(result.value);
      unawaited(_extendStored(conversationId, oldest, result.value));
    }
    ref.read(olderLoadingProvider.notifier).set(false);
    _loadingOlder = false;
    final now = state.value;
    if (result is! Ok<List<Message>> || now == null) return;
    final shown = {for (final m in now) m.id};
    final fresh = [
      for (final m in result.value)
        if (!shown.contains(m.id) && !m.createdAt.isAfter(oldest.createdAt)) m,
    ];
    final page = result.value
        .where((m) => !m.createdAt.isAfter(oldest.createdAt))
        .length;
    // Counted from the server's page, before shown rows are dropped: a row
    // live delivery already added must not make a full page look short.
    if (local != null) {
      _noOlder = local.end;
    } else if (page <= messagePageSize) {
      _noOlder = true;
    }
    final older = [
      for (final m in fresh)
        if (m.deletion != MessageDeletion.vanished) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (older.isEmpty) return;
    state = AsyncData([...older, ...now]);
    // The page came without previews, like the first read: one batched read
    // brings them, and with them each photo bubble's final size.
    unawaited(
      _fillPreviews(conversationId, () => ref.mounted && epoch == _epoch),
    );
  }

  /// The server page just read for [oldest] (rows at or before it, plus rows
  /// after) joins the stored block when that block reaches [oldest]: the phone
  /// then holds the page with no gap, so the chat's contiguous start moves
  /// down. A block that does not reach [oldest] is left alone.
  Future<void> _extendStored(
    String conversationId,
    Message oldest,
    List<Message> rows,
  ) async {
    final store = _storeOf(ref);
    if (store == null) return;
    final from = (await store.syncState(conversationId))?.contiguousFrom;
    if (from == null || from.isAfter(oldest.createdAt)) return;
    final older = [
      for (final m in rows)
        if (!m.createdAt.isAfter(oldest.createdAt)) m,
    ];
    await store.extendOlder(conversationId, [
      for (final m in older)
        if (m.deletion != MessageDeletion.vanished) m,
    ], reachedStart: older.length <= messagePageSize);
  }

  /// The mirror of [loadOlder] for a jumped window: reads the page after the
  /// newest shown message and appends it, so scrolling down always reaches the
  /// live end. A page shorter than [messagePageSize] is the live end: the
  /// window becomes the live list again (Realtime appends resume) and one
  /// verify read closes any gap. No-op unless [isJumped]; one read at a time;
  /// a failure is silent, the next scroll tries again.
  Future<void> loadNewer() async {
    final conversationId = ref.read(openConversationProvider);
    final current = state.value;
    if (!_jumped ||
        conversationId == null ||
        current == null ||
        state.isLoading ||
        _loadingNewer) {
      return;
    }
    final newest = current.where((m) => !m.isPending).lastOrNull;
    if (newest == null) return;
    final epoch = _epoch;
    _loadingNewer = true;
    final result = await ref
        .read(chatRepositoryProvider)
        .messagesAround(conversationId, newest);
    if (!ref.mounted || epoch != _epoch) return;
    _loadingNewer = false;
    final now = state.value;
    if (!_jumped || result is! Ok<List<Message>> || now == null) return;
    final shown = {for (final m in now) m.id};
    final fresh = [
      for (final m in result.value)
        if (!shown.contains(m.id) && !m.createdAt.isBefore(newest.createdAt)) m,
    ];
    // Counted before dropping vanished rows: a short page is the live end.
    final live = fresh.length < messagePageSize;
    final newer = [
      for (final m in fresh)
        if (m.deletion != MessageDeletion.vanished) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (live) {
      _jumped = false;
      _liveBeforeJump = null;
    }
    if (newer.isNotEmpty || live) state = AsyncData([...now, ...newer]);
    if (live) {
      final edits = _ownEdits;
      unawaited(
        _verify(conversationId, edits, () => ref.mounted && epoch == _epoch),
      );
    }
  }

  /// The first read can be served before the join took effect on the server:
  /// a message sent in between is in neither it nor the stream. A second read,
  /// after both, closes that window. Merged by id, so nothing is shown twice;
  /// an edit or delete that landed in the window replaces the old row.
  Future<void> _verify(
    String conversationId,
    int edits,
    bool Function() alive,
  ) async {
    if (!alive() || !ref.mounted) return;
    final result = await ref
        .read(chatRepositoryProvider)
        .messages(conversationId);
    // A delete or hide made meanwhile is not on the server yet: this read
    // would put the row back.
    if (!alive() || !ref.mounted || _jumped || edits != _ownEdits) return;
    if (ref.read(openConversationProvider) != conversationId) return;
    final current = state.value;
    if (result is! Ok<List<Message>> || current == null) return;
    _persist(result.value);
    var next = current;
    for (final m in result.value) {
      if (m.deletion == MessageDeletion.vanished) continue;
      final i = next.indexWhere((x) => x.id == m.id);
      if (i < 0) {
        next = [...next, m];
      } else if (_newer(m, next[i])) {
        final kept = next[i].attachmentPreview;
        next = [...next]
          ..[i] = m.attachmentPreview == null && kept != null
              ? m.withPreview(kept)
              : m;
      }
    }
    if (identical(next, current)) return;
    state = AsyncData(
      [...next]..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  /// Whether [read] is a later state of [shown] than what is on screen: a
  /// delete, or a later edit. Never the other way round -- a read that began
  /// before a live event must not undo it.
  static bool _newer(Message read, Message shown) {
    if (shown.isDeleted) return false;
    if (read.isDeleted) return true;
    final at = read.editedAt;
    final was = shown.editedAt;
    return at != null && (was == null || at.isAfter(was));
  }

  /// Reconciles this conversation's shown list with [SendQueueController]'s
  /// pending list for it: a new id is upserted in place (added if unseen,
  /// replacing an existing entry with the same id -- covers both a brand
  /// new pending bubble and the resolved row published just before the
  /// queue drops it, see SendQueueController._drain); an id that leaves the
  /// queue is removed from here only while still pending -- once resolved
  /// it was already upserted to the final, non-pending message above, and
  /// must stay.
  void _onQueueChanged(List<Message>? previous, List<Message> next) {
    // Sending from a jumped window goes back to live first, so the sent
    // message shows at the bottom without a gap.
    if (_jumped && next.isNotEmpty) returnToLive();
    _persist(next);
    final current = state.value;
    if (current == null) return;
    var list = current;
    for (final m in next) {
      final i = list.indexWhere((x) => x.id == m.id);
      if (i < 0) {
        list = [...list, m];
      } else if (!identical(list[i], m)) {
        list = [...list]..[i] = m;
      }
    }
    final nextIds = {for (final m in next) m.id};
    for (final m in previous ?? const <Message>[]) {
      if (nextIds.contains(m.id)) continue;
      final i = list.indexWhere((x) => x.id == m.id);
      if (i >= 0 && list[i].isPending) {
        list = [...list]..removeAt(i);
      }
    }
    if (!identical(list, current)) state = AsyncData(list);
  }

  String? get _me => switch (ref.read(sessionControllerProvider).value) {
    Allowed(:final member) => member.userId,
    _ => null,
  };

  /// A message deleted for everyone replaces its old self, and its photo
  /// leaves this phone's cache.
  void _deleted(Message message) {
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) return;
    final old = current[i];
    final path = old.attachmentPath;
    if (path != null) unawaited(ref.read(attachmentCacheProvider).remove(path));
    // A vanishing message keeps its text for the moment it takes to animate
    // away on this screen; the server no longer has it.
    final shown = message.deletion == MessageDeletion.vanished
        ? Message(
            id: old.id,
            conversationId: old.conversationId,
            senderId: old.senderId,
            body: old.body,
            createdAt: old.createdAt,
            deletion: MessageDeletion.vanished,
          )
        : message;
    state = AsyncData([...current]..[i] = shown);
  }

  /// An edited message replaces its old self, in place, on this screen --
  /// and on every other open screen through the same Realtime update.
  void _edited(Message message) {
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) return;
    state = AsyncData([...current]..[i] = _keepText(current[i], message));
  }

  /// [fresh] unless it is only the locked placeholder of a message whose readable text is already shown (the echo of my own locked send): then the shown text stays.
  Message _keepText(Message shown, Message fresh) =>
      isLockedPlaceholder(fresh.body) &&
          !isLockedPlaceholder(shown.body) &&
          fresh.deletion == null
      ? fresh.withPlain(shown.body, shown.linkPreview, sealed: shown.sealed)
      : fresh;

  /// Deletes [message] for everyone (the member's own, or any member's when
  /// they are a group admin). The placeholder shows here at once and is
  /// rolled back when the server refuses; other open screens get it through
  /// Realtime.
  Future<Result<void>> deleteForEveryone(Message message) async {
    _ownEdits++;
    final placeholder = Message(
      id: message.id,
      conversationId: message.conversationId,
      senderId: message.senderId,
      body: '',
      createdAt: message.createdAt,
      deletion: MessageDeletion.placeholder,
      deletedBy: _me,
    );
    _deleted(placeholder);
    final result = await ref
        .read(chatRepositoryProvider)
        .deleteForEveryone(message);
    if (result is Err && ref.mounted) _replace(message);
    if (result is Ok) _persist([placeholder]);
    return result;
  }

  /// Hides [message] from this member only (delete for me). It leaves the
  /// list at once and comes back when the server refuses.
  Future<Result<void>> hideForMe(Message message) async {
    _ownEdits++;
    final current = state.value;
    if (current != null) {
      state = AsyncData([
        for (final m in current)
          if (m.id != message.id) m,
      ]);
    }
    final result = await ref.read(chatRepositoryProvider).hideForMe(message);
    if (result is Ok) {
      final store = _storeOf(ref);
      if (store != null) unawaited(store.remove(message.id));
    }
    if (result is Err && ref.mounted) {
      final now = state.value;
      if (now != null && !now.any((m) => m.id == message.id)) {
        state = AsyncData(
          [...now, message]..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
        );
      }
    }
    return result;
  }

  /// Puts [message] back in its place (a refused delete), keeping every
  /// other change made meanwhile.
  void _replace(Message message) {
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) return;
    state = AsyncData([...current]..[i] = message);
  }

  /// Edits the member's own [message] to [body]. The screen shows an [Err]'s
  /// reason; on success the new text shows here at once, and on every other
  /// open screen through Realtime.
  Future<Result<Message>> editMessage(Message message, String body) async {
    final text = body.trim();
    // A direct chat with a verified partner edits the locked text with a fresh ciphertext; any other chat edits it plain. A locking failure edits nothing (never plain).
    final lock = await ref
        .read(textLockerProvider)
        .lock(
          conversationId: message.conversationId,
          messageId: message.id,
          text: text,
        );
    final Result<Message> result;
    switch (lock) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: null):
        result = await ref
            .read(chatRepositoryProvider)
            .editMessage(message, body);
      case Ok(:final value?):
        final repository = ref.read(encryptedMessageRepositoryProvider);
        if (repository == null) return const Err(DeniedFailure());
        final edited = await repository.edit(
          id: message.id,
          ciphertext: value.ciphertext,
          olmType: value.olmType,
        );
        // The stored row only holds the placeholder: this phone keeps the new text (an edit drops the link card).
        result = switch (edited) {
          Ok(:final value) => Ok(value.withPlain(text, null)),
          Err(:final failure) => Err(failure),
        };
    }
    if (result case Ok(:final value)) {
      _persist([value]);
      if (ref.mounted) _edited(value);
    }
    return result;
  }

  void _append(Message message) {
    // A jumped window has no live end: a live row is read when paging down
    // (loadNewer); appending it here would leave a gap.
    if (_jumped) return;
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) {
      // My own photo's stored row (the Realtime echo or the POST answer,
      // whichever is first) takes the pending bubble's place and keeps its
      // local image: one bubble, never two, and no swap to the downloaded
      // copy. Matched by caption and the photo's own preview (see
      // Message.isPendingOf), so photos in the air together never swap.
      final p = message.attachmentPath != null && message.isFrom(_me ?? '')
          ? current.indexWhere((m) => m.isPendingOf(message))
          : -1;
      if (p < 0 && !message.isPending) {
        // A row older than the oldest shown one (Realtime delivered it late) is
        // ignored, like the open's buffered merge: loadOlder fetches it in
        // order. A row inside the shown range goes in sorted, never at the end.
        final oldest = current.where((m) => !m.isPending).firstOrNull;
        if (oldest != null && message.createdAt.isBefore(oldest.createdAt)) {
          return;
        }
        final at = current.indexWhere(
          (m) => !m.isPending && m.createdAt.isAfter(message.createdAt),
        );
        state = AsyncData(
          at < 0 ? [...current, message] : ([...current]..insert(at, message)),
        );
        return;
      }
      state = AsyncData(
        p >= 0
            ? ([...current]
                ..[p] = message.withLocalImage(current[p].localImage))
            : [...current, message],
      );
    } else if (!identical(current[i], message)) {
      // The echo and the answer are both this message: keep the phone's
      // own photo across the second one.
      final kept = current[i].localImage;
      final text = _keepText(current[i], message);
      state = AsyncData(
        [...current]
          ..[i] = text.localImage == null && kept != null
              ? text.withLocalImage(kept)
              : text,
      );
    }
  }

  /// The bubble shown from the phone while [image] uploads.
  Message _pendingPhoto(
    String conversationId,
    PickedImage image,
    String body,
    String id,
  ) => Message(
    id: id,
    conversationId: conversationId,
    senderId: _me ?? '',
    body: body.trim(),
    createdAt: DateTime.now(),
    localImage: image.bytes,
    attachmentPreview: image.preview,
    photoGroup: image.photoGroup,
  );

  /// Takes the messages with these ids out of the shown list (pending
  /// bubbles of photos that will not be sent).
  void _dropMessages(Set<String> ids) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final m in current)
        if (!ids.contains(m.id)) m,
    ]);
  }

  /// Sends [chosen], picked in the attachment sheet's own grid, with an
  /// optional [body].
  ///
  /// [shown] is the pending bubble of this photo when the caller (see
  /// [sendImages]) has already put it in the list; then none is added here.
  ///
  /// Returns null when [chosen] is null -- the member backed out of the
  /// sheet, which is not a failure, and the composer must not report one.
  Future<Result<Message>?> sendImage({
    String body = '',
    PickedImage? chosen,
    Message? shown,
  }) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    final image = chosen;
    if (image == null) return null;

    // Shown at once from the phone while it uploads; replaced by the stored
    // message, or taken away again if the upload fails.
    final pending =
        shown ??
        _pendingPhoto(
          conversationId,
          image,
          body,
          'pending-${DateTime.now().microsecondsSinceEpoch}',
        );
    if (shown == null) {
      returnToLive(); // no-op unless jumped; see _onQueueChanged
      _append(pending);
    }
    final result = await ref
        .read(chatRepositoryProvider)
        .sendImage(
          conversationId: conversationId,
          image: image,
          body: body,
          replyTo: ref.read(replyingToProvider)?.id,
        );
    if (!ref.mounted) return result;
    // Stored row first: it takes the pending bubble's place (see _append),
    // so the photo never leaves the screen. Whatever pending is left over
    // (a failed send) is removed after.
    if (result case Ok(:final value)) {
      _persist([value]);
      _append(value);
      // The phone's own copy stays on the stored entry to the end, even when
      // the stored row was not paired with its pending bubble above.
      final stored = state.value;
      final at = stored?.indexWhere((m) => m.id == value.id) ?? -1;
      if (stored != null && at >= 0 && stored[at].localImage == null) {
        state = AsyncData(
          [...stored]..[at] = stored[at].withLocalImage(pending.localImage),
        );
      }
      if (ref.mounted) ref.read(replyingToProvider.notifier).clear();
    }
    final current = state.value;
    if (current != null && current.any((m) => m.id == pending.id)) {
      state = AsyncData([
        for (final m in current)
          if (m.id != pending.id) m,
      ]);
    }
    return result;
  }

  /// Sends the phone contact [contact] to the open conversation: shown at once
  /// as a pending bubble, then the server stores it under the same client-made
  /// id, so a retried send is harmless and the Realtime echo of the stored row
  /// replaces the bubble in place. Returns the server's answer; a failed send
  /// takes the bubble away.
  Future<Result<void>> sendContact(SharedContact contact) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null || !contact.isSendable) {
      return const Err(DeniedFailure());
    }
    final id = randomMessageId();
    final pending = Message(
      id: id,
      conversationId: conversationId,
      senderId: _me ?? '',
      body: contact.body,
      createdAt: DateTime.now(),
      contact: true,
      sending: true,
    );
    returnToLive(); // no-op unless jumped; see _onQueueChanged
    _append(pending);
    final result = await ref
        .read(contactShareRepositoryProvider)
        .send(conversationId, id, contact);
    if (!ref.mounted) return result;
    if (result is Ok) {
      _replace(
        Message(
          id: id,
          conversationId: conversationId,
          senderId: pending.senderId,
          body: contact.body,
          createdAt: pending.createdAt,
          contact: true,
        ),
      );
    } else {
      final current = state.value;
      if (current != null) {
        state = AsyncData([
          for (final m in current)
            if (m.id != id) m,
        ]);
      }
    }
    return result;
  }

  /// Sends the poll [draft] to the open conversation: shown at once as a
  /// pending bubble (the poll on it, votes closed until it is stored), then the
  /// server stores it under the same client-made id, so a retried send is
  /// harmless and the Realtime echo of the stored row replaces the bubble in
  /// place. Returns the server's answer; a failed send takes the bubble away.
  Future<Result<void>> sendPoll(PollDraft draft) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    final id = randomMessageId();
    final question = draft.question.trim();
    final options = cleanPollOptions(draft.options);
    final pending = Message(
      id: id,
      conversationId: conversationId,
      senderId: _me ?? '',
      body: question,
      createdAt: DateTime.now(),
      poll: true,
      sending: true,
    );
    returnToLive(); // no-op unless jumped; see _onQueueChanged
    ref
        .read(pollsProvider.notifier)
        .addLocal(
          Poll(
            messageId: id,
            question: question,
            options: [
              for (var i = 0; i < options.length; i++)
                PollOption(id: 'local-$id-$i', text: options[i], votes: 0),
            ],
            multiple: draft.multiple,
            anonymous: draft.anonymous,
            closed: false,
            voters: 0,
          ),
        );
    _append(pending);
    final result = await ref
        .read(pollRepositoryProvider)
        .createPoll(conversationId, id, draft);
    if (!ref.mounted) return result;
    if (result is Ok) {
      // Stored: no longer pending. The real option ids come with a reload.
      _replace(
        Message(
          id: id,
          conversationId: conversationId,
          senderId: pending.senderId,
          body: question,
          createdAt: pending.createdAt,
          poll: true,
        ),
      );
      unawaited(ref.read(pollsProvider.notifier).ensure(id, force: true));
    } else {
      final current = state.value;
      if (current != null) {
        state = AsyncData([
          for (final m in current)
            if (m.id != id) m,
        ]);
      }
    }
    return result;
  }

  /// Sends [images] to the open conversation, one message per photo, in
  /// order -- [body] as the caption of the first only, the rest with none.
  /// Photos picked together become albums of at most 10 sharing a group id
  /// (a lone leftover photo stays a plain photo); an album's pending
  /// bubbles all show at once, before the first upload, and each turns
  /// into its stored photo in turn.
  /// Stops at the first [Err] and returns it, taking the bubbles of the
  /// photos not sent off the screen; otherwise returns [Ok(null)] once
  /// every image has been sent. An empty [images] sends nothing and
  /// returns [Ok(null)] at once.
  Future<Result<void>> sendImages(
    List<PickedImage> images, {
    String body = '',
  }) async {
    if (images.isEmpty) return const Ok(null);
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    for (var start = 0; start < images.length; start += 10) {
      final end = start + 10 < images.length ? start + 10 : images.length;
      final group = end - start > 1 ? randomMessageId() : null;
      final chunk = [
        for (var i = start; i < end; i++)
          group == null ? images[i] : images[i].inGroup(group),
      ];
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final shown = [
        for (var k = 0; k < chunk.length; k++)
          _pendingPhoto(
            conversationId,
            chunk[k],
            start + k == 0 ? body : '',
            'pending-$stamp-$k',
          ),
      ];
      returnToLive(); // no-op unless jumped; see _onQueueChanged
      shown.forEach(_append);
      for (var k = 0; k < chunk.length; k++) {
        final result = await sendImage(
          body: start + k == 0 ? body : '',
          chosen: chunk[k],
          shown: shown[k],
        );
        if (result case Err(:final failure)) {
          if (ref.mounted) {
            _dropMessages({for (final m in shown.skip(k + 1)) m.id});
          }
          return Err(failure);
        }
      }
    }
    return const Ok(null);
  }

  /// A short-lived URL for an attachment, or an [Err] with its reason.
  Future<Result<Uri>> attachmentUrl(String path) =>
      ref.read(chatRepositoryProvider).attachmentUrl(path);

  /// Sends a copy of [message] to each of [conversationIds]; the chat list
  /// then shows them. With [album], every photo of the album [message]
  /// belongs to is sent, in order, as a new album of its own in each
  /// target chat (a fresh group id per target, never the original); a
  /// single photo is forwarded without any group.
  Future<Result<void>> forward(
    Message message,
    List<String> conversationIds, {
    bool album = false,
  }) async {
    final photos = album
        ? albumOf(state.value ?? const <Message>[], message)
        : [message];
    Result<void> result = const Ok(null);
    if (photos.length < 2) {
      // One message (a lone photo leaves any album): one call for all targets.
      final one = photos.first;
      result = await _forwardOne(
        one.photoGroup == null ? one : one.withPhotoGroup(null),
        conversationIds,
      );
    } else {
      // An album: every target gets its own fresh group id.
      for (final target in conversationIds) {
        final group = randomMessageId();
        for (final photo in photos) {
          result = await ref.read(chatRepositoryProvider).forward(
            photo.withPhotoGroup(group),
            [target],
          );
          if (result is Err) break;
        }
        if (result is Err) break;
      }
    }
    if (result is Ok && ref.mounted) {
      unawaited(ref.read(conversationListProvider.notifier).reloadQuietly());
    }
    return result;
  }

  /// Forwards one message to each target. A plain text goes through the send path: a direct chat with a verified partner gets it locked, any other chat the ordinary copy. A locking failure stops the forward (never plain). Everything else (photos, files, stickers, ...) is copied as before.
  Future<Result<void>> _forwardOne(
    Message message,
    List<String> conversationIds,
  ) async {
    final repository = ref.read(chatRepositoryProvider);
    final isText =
        message.body.isNotEmpty &&
        message.attachmentPath == null &&
        message.localImage == null &&
        message.stickerId == null &&
        !message.albumCard &&
        !message.poll &&
        !message.contact &&
        message.location == null &&
        message.file == null &&
        message.adminMsg == null;
    if (!isText) return repository.forward(message, conversationIds);
    // A message this phone could not unlock only has the placeholder as text: never forward that.
    if (isLockedPlaceholder(message.body)) {
      return const Err(DeniedFailure());
    }
    for (final target in conversationIds) {
      final id = randomMessageId();
      final lock = await ref
          .read(textLockerProvider)
          .lock(conversationId: target, messageId: id, text: message.body);
      switch (lock) {
        case Err(:final failure):
          return Err(failure);
        case Ok(value: null):
          final sent = await repository.forward(message, [target]);
          if (sent is Err) return sent;
        case Ok(:final value?):
          final locked = ref.read(encryptedMessageRepositoryProvider);
          if (locked == null) return const Err(DeniedFailure());
          final sent = await locked.send(
            id: id,
            conversationId: target,
            ciphertext: value.ciphertext,
            olmType: value.olmType,
            forwarded: true,
          );
          if (sent case Err(:final failure)) return Err(failure);
      }
    }
    return const Ok(null);
  }

  /// Forwards [message] to [conversationIds] and to [personIds]: a person
  /// with no chat yet gets a direct chat first (created on send). The first
  /// chat that cannot be created is the [Err]; nothing is sent then.
  Future<Result<void>> forwardTo(
    Message message, {
    required List<String> conversationIds,
    List<String> personIds = const [],
    bool album = false,
  }) async {
    final ids = [...conversationIds];
    for (final person in personIds) {
      final started = await ref
          .read(conversationListProvider.notifier)
          .startWith(person);
      switch (started) {
        case Ok(:final value):
          if (!ids.contains(value)) ids.add(value);
        case Err(:final failure):
          return Err(failure);
      }
    }
    return forward(message, ids, album: album);
  }

  /// Replaces the shown messages with a window around [anchor] (oldest
  /// first, anchor included) -- for jumping to a search hit older than what
  /// is currently loaded. The [Err] reason is the caller's to show; state is
  /// left as it was on failure. Call [returnToLive] to go back to the live,
  /// newest window.
  Future<Result<void>> jumpToAround(Message anchor) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    _requestedAnchorId = anchor.id;
    // From the phone when it provably holds the whole window, else the server.
    final local = await _storedAround(conversationId, anchor);
    final Result<List<Message>> result = local != null
        ? Ok(local)
        : await ref
              .read(chatRepositoryProvider)
              .messagesAround(conversationId, anchor);
    if (local == null && result is Ok<List<Message>> && ref.mounted) {
      _persist(result.value);
    }
    if (result case Ok(:final value)
        when ref.mounted &&
            ref.read(openConversationProvider) == conversationId &&
            _requestedAnchorId == anchor.id) {
      if (!_jumped) _liveBeforeJump = state.value;
      _jumped = true;
      // A page read for the old list must not land in this window.
      _epoch++;
      _loadingOlder = false;
      _loadingNewer = false;
      ref.read(olderLoadingProvider.notifier).set(false);
      _noOlder = false;
      state = AsyncData(value);
    }
    return switch (result) {
      Ok() => const Ok(null),
      Err(:final failure) => Err(failure),
    };
  }

  /// Back to the live, newest window -- undoes [jumpToAround]. The live list
  /// shown before the jump is back at once (no network wait) and the re-read
  /// heals it. A no-op when nothing was jumped.
  void returnToLive() {
    if (!_jumped) return;
    _jumped = false;
    final live = _liveBeforeJump;
    _liveBeforeJump = null;
    if (live != null) {
      state = AsyncData(live);
    } else {
      _fromJump = true;
    }
    ref.invalidateSelf();
  }
}

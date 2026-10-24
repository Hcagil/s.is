part of 'chat_controllers.dart';

/// Keeps the on-phone store current: catch-up after offline or a killed app
/// (the change feed), and the full-history fill of a new phone. One per
/// account (rebuilt when the user id changes).
final storeSyncProvider = Provider<StoreSyncController>((ref) {
  ref.watch(currentUserIdProvider);
  return StoreSyncController(ref);
});

class StoreSyncController {
  StoreSyncController(this._ref);
  final Ref _ref;

  /// The cursor of a catch-up starts this far back, so a row that committed
  /// late is not skipped; rows are written by id, so a repeat is harmless.
  static const _overlap = Duration(seconds: 5);
  static const _feedPage = 500;
  static const _fillPage = 300;
  static const _gap = Duration(milliseconds: 250);
  static const _nilId = '00000000-0000-0000-0000-000000000000';
  bool _running = false;
  bool _again = false;

  /// True when work on [store] must stop: the account or store changed, or a
  /// newer [run] asked for a fresh pass (the loops resume from stored state).
  bool _halted(MessageStore store) =>
      !_ref.mounted || _again || !identical(_storeOf(_ref), store);

  /// Entry point for app start, resume and a Realtime reconnect. One pass at a
  /// time; a call during a pass makes it restart (catch-up first).
  Future<void> run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        final store = _storeOf(_ref);
        if (store == null) return;
        await _once(store);
      } while (_again && _ref.mounted);
      // The pass may have stored readable text of locked messages: refresh the list previews from the phone (no network).
      if (_ref.mounted && _ref.exists(conversationListProvider)) {
        unawaited(
          _ref.read(conversationListProvider.notifier).unlockPreviews(),
        );
      }
    } catch (e, st) {
      log('$e', name: 'sis.store', error: e, stackTrace: st);
    } finally {
      _running = false;
    }
  }

  /// Ids of the member's chats, most recent first; null when the list cannot
  /// be read (offline): a pass then does nothing.
  Future<List<String>?> _chatIds() async {
    final r = await _ref.read(chatRepositoryProvider).conversations();
    return r is Ok<List<Conversation>> ? [for (final c in r.value) c.id] : null;
  }

  /// One pass: the change feed first (or its start on a new phone), then the
  /// history fill.
  Future<void> _once(MessageStore store) async {
    if (_ref.read(sessionControllerProvider).value is! Allowed) return;
    final ids = await _chatIds();
    if (ids == null || _halted(store)) return;
    final mark = _ref.read(catchUpMarkProvider);
    final start = mark.stamp();
    final cursor = await store.cursor();
    final complete = cursor == null
        ? await _startFeed(store)
        : await _applyChanges(store, cursor, ids.toSet());
    // The feed was read to its end: locked reactions read before this pass began may now be opened (their older messages are open).
    if (complete && !_halted(store)) mark.passDone(start);
    if (!_halted(store)) await _backfill(store, ids);
  }

  /// A new phone: the feed starts at the newest change that exists now,
  /// taken BEFORE the history fill, so anything changing meanwhile is caught
  /// by the next pass.
  Future<bool> _startFeed(MessageStore store) async {
    final r = await _ref.read(chatRepositoryProvider).newestChange();
    if (r is Ok<ChangeCursor?> && r.value != null && !_halted(store)) {
      await store.saveCursor(r.value!);
    }
    return r is Ok<ChangeCursor?> && !_halted(store);
  }

  /// Writes changed rows of the member's current chats; a legacy vanished row
  /// leaves the phone.
  Future<void> _write(
    MessageStore store,
    List<Message> rows,
    Set<String> chats,
  ) async {
    final keep = <Message>[];
    final gone = <String>[];
    for (final m in rows) {
      if (!chats.contains(m.conversationId)) continue;
      if (m.deletion == MessageDeletion.vanished) {
        gone.add(m.id);
      } else {
        keep.add(m);
      }
    }
    for (final id in gone) {
      _ref.read(messageOpenerProvider).forget(id);
      await store.remove(id);
    }
    if (keep.isNotEmpty) await store.upsertAll(keep);
  }

  /// Reads the change feed after [from] page by page and writes it; the saved
  /// cursor only moves forward, after each page is written. Returns true when
  /// the feed was read to its end.
  Future<bool> _applyChanges(
    MessageStore store,
    ChangeCursor from,
    Set<String> chats,
  ) async {
    var high = from;
    // The first page starts a few seconds back (late commits).
    var at = ChangeCursor(from.updatedAt.subtract(_overlap), _nilId);
    while (!_halted(store)) {
      final r = await _ref
          .read(chatRepositoryProvider)
          .changesSince(at, limit: _feedPage);
      if (r is! Ok<ChangePage> || _halted(store)) return false;
      final last = r.value.last;
      if (last == null) return true;
      await _write(store, r.value.messages, chats);
      final ahead =
          last.updatedAt.isAfter(high.updatedAt) ||
          (last.updatedAt.isAtSameMomentAs(high.updatedAt) &&
              last.id.compareTo(high.id) > 0);
      if (ahead && !_halted(store)) {
        high = last;
        await store.saveCursor(high);
      }
      if (r.value.messages.length < _feedPage) return true;
      at = last;
    }
    return false;
  }

  /// The open chat comes first: waits (at most about 3 seconds) while it is
  /// still loading its first page.
  Future<void> _yieldToOpenChat() async {
    for (
      var i = 0;
      i < 10 &&
          _ref.read(openConversationProvider) != null &&
          _ref.read(messagesProvider).isLoading;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// The history fill, newest chats first, one chat at a time, one request at
  /// a time. Resumes from each chat's stored state.
  Future<void> _backfill(MessageStore store, List<String> ids) async {
    for (final id in ids) {
      if (_halted(store)) return;
      await _fillChat(store, id);
    }
  }

  /// Fills one chat: its newest page when the phone has none, then older pages
  /// of _fillPage rows until the first message is stored. Text and metadata
  /// only; media is never fetched here. A failed request stops this chat until
  /// the next pass.
  Future<void> _fillChat(MessageStore store, String id) async {
    var sync = await store.syncState(id);
    if (sync == null) {
      await _yieldToOpenChat();
      if (_halted(store)) return;
      final r = await _ref.read(chatRepositoryProvider).messages(id);
      if (r is! Ok<List<Message>> || _halted(store)) return;
      await store.reconcilePage(id, [
        for (final m in r.value)
          if (m.deletion != MessageDeletion.vanished) m,
      ], reachedStart: r.value.length < messagePageSize);
      sync = await store.syncState(id);
    }
    while (sync != null && !sync.complete && sync.contiguousFrom != null) {
      await _yieldToOpenChat();
      if (_halted(store)) return;
      final before = sync.contiguousFrom!;
      final r = await _ref
          .read(chatRepositoryProvider)
          .messagesBefore(id, before, limit: _fillPage);
      if (r is! Ok<List<Message>> || _halted(store)) return;
      await store.extendOlder(id, [
        for (final m in r.value)
          if (m.deletion != MessageDeletion.vanished) m,
      ], reachedStart: r.value.length < _fillPage);
      sync = await store.syncState(id);
      // No progress (a whole page at one instant): stop rather than loop.
      final from = sync?.contiguousFrom;
      if (sync == null ||
          (!sync.complete && (from == null || !from.isBefore(before)))) {
        return;
      }
      await Future<void>.delayed(_gap);
    }
  }
}

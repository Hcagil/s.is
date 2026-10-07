part of 'chat_controllers.dart';

/// The open conversation's polls, by message id, live.
final pollsProvider =
    AsyncNotifierProvider.autoDispose<PollsController, PollsByMessage>(
      PollsController.new,
      retry: _never,
    );

class PollsController extends AsyncNotifier<PollsByMessage> {
  // Changes that arrive while the load is on its way, applied once it lands.
  final _early = <PollChange>[];

  // Message ids being fetched by ensure().
  final _fetching = <String>{};

  // Bumped by every build: an answer that lands after the chat closed or
  // switched must not touch the new state.
  int _generation = 0;

  @override
  Future<PollsByMessage> build() async {
    _early.clear();
    _fetching.clear();
    final generation = ++_generation;
    // Closing or switching the chat bumps it too, so a late answer is dropped.
    ref.onDispose(() => _generation++);
    final conversationId = ref.watch(openConversationProvider);
    ref.watch(currentUserIdProvider);
    if (conversationId == null) return const {};
    final repo = ref.read(pollRepositoryProvider);
    // Per-build flag, same reasoning as ReactionsController: the provider
    // REBUILDS when the chat closes or another opens. The join is not awaited
    // before the load; a failed or slow join only costs the live part, and
    // events before the load lands are buffered by _saw.
    var live = true;
    ref.onDispose(() => live = false);
    unawaited(
      repo.pollUpdates(conversationId).then((joined) {
        if (joined case Ok(:final value)) {
          final sub = value.listen(_saw);
          if (live) {
            ref.onDispose(sub.cancel);
          } else {
            unawaited(sub.cancel());
          }
          if (live) unawaited(_reconcile(conversationId, generation));
        }
      }),
    );
    final loaded = switch (await repo.polls(conversationId)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    return _early.fold<PollsByMessage>({
      for (final p in loaded) p.messageId: p,
    }, applyPollChange);
  }

  void _saw(PollChange change) {
    final current = state.value;
    if (state.isLoading || current == null) {
      _early.add(change);
      return;
    }
    final next = applyPollChange(current, change);
    if (!identical(next, current)) state = AsyncData(next);
  }

  /// Once, after the join: re-reads the polls and puts them over the current
  /// ones (fetched wins per poll); polls only shown here are kept.
  Future<void> _reconcile(String conversationId, int generation) async {
    try {
      await future;
    } catch (_) {
      return; // the load failed; nothing to reconcile
    }
    if (generation != _generation) return;
    final fetched = await ref
        .read(pollRepositoryProvider)
        .polls(conversationId);
    final current = state.value;
    if (generation != _generation || current == null) return;
    if (fetched case Ok(:final value)) {
      state = AsyncData({...current, for (final p in value) p.messageId: p});
    }
  }

  /// Puts [poll] (the member's own, just created) on screen at once.
  void addLocal(Poll poll) => _put(poll);

  /// Loads one poll that is not here yet, or reloads it when [force]; a
  /// bubble calls this when it meets a poll message it has no data for. One
  /// fetch per id at a time; an Err or a missing poll is ignored.
  Future<void> ensure(String messageId, {bool force = false}) async {
    final current = state.value;
    if (current == null || _fetching.contains(messageId)) return;
    if (!force && current.containsKey(messageId)) return;
    _fetching.add(messageId);
    final generation = _generation;
    try {
      final fetched = await ref.read(pollRepositoryProvider).poll(messageId);
      if (generation != _generation) return;
      if (fetched case Ok(:final value?)) _put(value);
    } finally {
      _fetching.remove(messageId);
    }
  }

  /// Sets the member's choice to exactly [chosen] (empty = retract). Shown at
  /// once, rolled back when the server answers Err. Returns the server's
  /// answer; Err(DeniedFailure) when the poll is not loaded, Err(PollClosed)
  /// when it is already closed here; Ok(null) without a call when it changes
  /// nothing.
  Future<Result<void>> vote(String messageId, Set<String> chosen) async {
    final poll = state.value?[messageId];
    if (poll == null) return const Err(DeniedFailure());
    if (poll.closed) return const Err(PollClosedFailure());
    final before = poll.mine;
    if (before.length == chosen.length && before.containsAll(chosen)) {
      return const Ok(null);
    }
    if (!poll.multiple && chosen.length > 1) return const Err(DeniedFailure());
    final generation = _generation;
    _put(poll.withMyVotes(chosen));
    final result = await ref
        .read(pollRepositoryProvider)
        .vote(messageId, chosen);
    if (generation != _generation) return result;
    if (result case Err(:final failure)) {
      final latest = state.value?[messageId];
      if (latest != null) {
        final back = latest.withMyVotes(before);
        _put(failure is PollClosedFailure ? back.copyWith(closed: true) : back);
      }
    }
    return result;
  }

  /// Retracts the member's vote.
  Future<Result<void>> retract(String messageId) =>
      vote(messageId, const <String>{});

  /// Closes the member's own poll: shown closed at once, reopened when the
  /// server answers Err. Returns the server's answer.
  Future<Result<void>> close(String messageId) async {
    final poll = state.value?[messageId];
    if (poll == null) return const Err(DeniedFailure());
    final generation = _generation;
    _put(poll.copyWith(closed: true));
    final result = await ref.read(pollRepositoryProvider).close(messageId);
    if (generation != _generation) return result;
    if (result case Err()) {
      final latest = state.value?[messageId];
      if (latest != null) _put(latest.copyWith(closed: false));
    }
    return result;
  }

  void _put(Poll poll) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData({...current, poll.messageId: poll});
  }
}

/// Who voted for what on a public poll, for the voters list; empty for an
/// anonymous poll except your own votes (the server never shows others).
final pollVotesProvider = FutureProvider.autoDispose
    .family<List<PollVote>, String>((ref, messageId) async {
      ref.watch(currentUserIdProvider);
      return switch (await ref.read(pollRepositoryProvider).voters(messageId)) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
    }, retry: _never);

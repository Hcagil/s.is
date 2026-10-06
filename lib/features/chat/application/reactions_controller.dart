part of 'chat_controllers.dart';

/// The open conversation's reactions, grouped by message, live.
final reactionsProvider =
    AsyncNotifierProvider.autoDispose<ReactionsController, ReactionsByMessage>(
      ReactionsController.new,
      retry: _never,
    );

/// How many times the member used each emoji (their last 300 reactions); feeds
/// the reactions bar. Refreshed after each reaction they set.
final reactionUsageProvider = FutureProvider.autoDispose<Map<String, int>>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  return switch (await ref.read(reactionRepositoryProvider).myReactionUsage()) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: _never);

class ReactionsController extends AsyncNotifier<ReactionsByMessage> {
  // Reactions that arrive while the load is on its way, applied once it lands.
  final _early = <Reaction>[];

  // Bumped by every build: an answer that lands after the chat closed or
  // switched must not touch the new state.
  int _generation = 0;

  @override
  Future<ReactionsByMessage> build() async {
    _early.clear();
    _generation++;
    final conversationId = ref.watch(openConversationProvider);
    ref.watch(currentUserIdProvider);
    if (conversationId == null) return const {};
    final repo = ref.read(reactionRepositoryProvider);
    // Per-build flag, same reasoning as ReadMarksController: the provider
    // REBUILDS when the chat closes or another opens, so `ref.mounted` cannot
    // tell a stale join. The join is not awaited before the load; a failed or
    // slow join only costs the live part, and events before the load lands are
    // buffered by _saw.
    var live = true;
    ref.onDispose(() => live = false);
    unawaited(
      repo.reactionUpdates(conversationId).then((joined) {
        if (joined case Ok(:final value)) {
          final sub = value.listen(_saw);
          if (live) {
            ref.onDispose(sub.cancel);
          } else {
            unawaited(sub.cancel());
          }
        }
      }),
    );
    final loaded = switch (await repo.reactions(conversationId)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    return _early.fold<ReactionsByMessage>(
      groupReactions(loaded),
      applyReaction,
    );
  }

  void _saw(Reaction reaction) {
    final current = state.value;
    if (state.isLoading || current == null) {
      _early.add(reaction);
      return;
    }
    state = AsyncData(applyReaction(current, reaction));
  }

  /// Sets the caller's reaction on [messageId] to [emoji], or clears it when
  /// [emoji] is null (the caller decides set vs clear; never a toggle here).
  /// Shown at once, rolled back to the previous reaction when the server
  /// answers Err. Returns the server's answer: Ok(null) without a call when it
  /// changes nothing; Err(DeniedFailure) when not signed in or the reactions
  /// are not loaded.
  Future<Result<void>> react(String messageId, String? emoji) async {
    final me = ref.read(currentUserIdProvider);
    final current = state.value;
    if (me == null || current == null) return const Err(DeniedFailure());
    final before = myReaction(current[messageId] ?? const <Reaction>[], me);
    if (before == emoji) return const Ok(null);
    final generation = _generation;
    state = AsyncData(
      applyReaction(
        current,
        Reaction(messageId: messageId, userId: me, emoji: emoji),
      ),
    );
    final result = await ref
        .read(reactionRepositoryProvider)
        .setReaction(messageId, emoji);
    // Closed or switched meanwhile: the new state is not ours to touch.
    if (generation != _generation) return result;
    switch (result) {
      case Err():
        final latest = state.value;
        if (latest != null) {
          state = AsyncData(
            applyReaction(
              latest,
              Reaction(messageId: messageId, userId: me, emoji: before),
            ),
          );
        }
      case Ok():
        ref.invalidate(reactionUsageProvider);
    }
    return result;
  }
}

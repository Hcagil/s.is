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

  // While a reconcile fetch is on its way: every reaction applied meanwhile
  // (live events, own changes, rollbacks), re-applied on top of the fetched
  // state so the fetch never overwrites something newer. Null otherwise.
  List<Reaction>? _since;

  // A reconcile asked for while one is running: run once more after it.
  bool _rerun = false;

  // Bumped by every build: an answer that lands after the chat closed or
  // switched must not touch the new state.
  int _generation = 0;

  // Messages the member changed in this opening: never re-locked behind their back.
  final _touched = <String>{};

  // Waits a moment before re-locking the member's older plain reactions, so the first paint and the member's own first tap go first.
  static const _relockDelay = Duration(milliseconds: 40);

  @override
  Future<ReactionsByMessage> build() async {
    _early.clear();
    _since = null;
    _rerun = false;
    _touched.clear();
    final generation = ++_generation;
    // Closing or switching the chat bumps it too, so a late answer is dropped.
    ref.onDispose(() => _generation++);
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
    // Locked reactions the opener kept hidden (their older messages may not be open yet) are read again after each complete message catch-up.
    final mark = ref.read(catchUpMarkProvider);
    final passes = mark.passes.listen((_) {
      if (mark.takeHolding()) unawaited(_reconcile(conversationId, generation));
    });
    ref.onDispose(passes.cancel);
    unawaited(
      repo.reactionUpdates(conversationId).then((joined) {
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
    // Locked reactions share the Olm chains with locked texts: the chat's messages open first. No timeout: a slow load only delays the reactions. A failed message load fails this load too (locked reactions stay unopened; nothing is shown as text) and the load runs again once the messages are there.
    // Only when the chat screen already holds the messages (ref.exists): nothing is built just to wait for it.
    if (ref.exists(messagesProvider)) {
      ref.listen(messagesProvider, (_, next) {
        if (state.hasError && next.hasValue) ref.invalidateSelf();
      });
      await ref.read(messagesProvider.future);
    }
    if (generation != _generation) return const {};
    final loaded = switch (await repo.reactions(conversationId)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    final relock = Timer(_relockDelay, () {
      unawaited(_relockPlain(conversationId, generation, loaded));
    });
    ref.onDispose(relock.cancel);
    return _early.fold<ReactionsByMessage>(
      groupReactions(loaded),
      applyReaction,
    );
  }

  /// Once per opened chat: the caller's own PLAIN reactions (not [Reaction.locked]) are locked and sent again with set_reaction_encrypted, so reactions made before this build do not stay readable on the server (the server clears plain ones of a private chat later). Stops at the first Err or Ok(null) from the locker (a plain chat, no keys, offline): nothing is ever sent plain here. At most 100 per opening. The saved copy is written only after the server accepted the bytes.
  Future<void> _relockPlain(
    String conversationId,
    int generation,
    List<Reaction> loaded,
  ) async {
    final me = ref.read(currentUserIdProvider);
    if (me == null) return;
    final mine = [
      for (final r in loaded)
        if (r.userId == me &&
            r.emoji != null &&
            !r.locked &&
            !_touched.contains(r.messageId))
          r,
    ];
    for (final r in mine.take(100)) {
      if (generation != _generation) return;
      if (_touched.contains(r.messageId)) continue;
      final locked = await ref
          .read(textLockerProvider)
          .lockReaction(
            conversationId: conversationId,
            messageId: r.messageId,
            emoji: r.emoji!,
          );
      if (generation != _generation) return;
      if (locked case Ok(:final value?)) {
        final repo = ref.read(reactionRepositoryProvider);
        // Compare-and-set on the server (only a row still plain is replaced), so a newer change or removal, from this or a second phone, is never undone.
        final applied = switch (await repo.relockPlain(
          r.messageId,
          value.ciphertext,
          value.olmType,
        )) {
          Ok(value: final done) => done,
          Err() => false,
        };
        if (generation != _generation) return;
        if (applied) {
          await ref
              .read(reactionOpenerProvider)
              .rememberOwn(r.messageId, me, value.ciphertext, r.emoji!);
        }
      } else {
        return;
      }
    }
  }

  void _saw(Reaction reaction) {
    final current = state.value;
    if (state.isLoading || current == null) {
      _early.add(reaction);
      return;
    }
    _apply(reaction);
  }

  void _apply(Reaction reaction) {
    final current = state.value;
    if (current == null) return;
    _since?.add(reaction);
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
    _touched.add(messageId);
    _apply(Reaction(messageId: messageId, userId: me, emoji: emoji));

    final result = await _send(messageId, emoji, me);
    // Closed or switched meanwhile: the new state is not ours to touch.
    if (generation != _generation) return result;
    switch (result) {
      case Err():
        final latest = state.value;
        if (latest != null) {
          _apply(Reaction(messageId: messageId, userId: me, emoji: before));
        }
      case Ok():
        // The live echo of our own locked row can arrive before the copy is saved and then reads as a removal; show the accepted change again.
        _apply(Reaction(messageId: messageId, userId: me, emoji: emoji));
        ref.invalidate(reactionUsageProvider);
    }
    return result;
  }

  /// Sends the change. A clear is always the plain call. A set is locked first ([TextLocker.lockReaction]); the locked bytes are saved on the phone once the server accepted them, and a retryable network failure is retried once with the same bytes. Ok(null) from the locker (a group, a bot chat, a person with no published keys) sends the plain call, which the server refuses in a chat that is already private. A locking failure is returned as it is: never a fallback to plain.
  Future<Result<void>> _send(String messageId, String? emoji, String me) async {
    final repo = ref.read(reactionRepositoryProvider);
    final conversationId = ref.read(openConversationProvider);
    if (emoji == null || conversationId == null) {
      return repo.setReaction(messageId, emoji);
    }
    final locked = await ref
        .read(textLockerProvider)
        .lockReaction(
          conversationId: conversationId,
          messageId: messageId,
          emoji: emoji,
        );
    switch (locked) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: null):
        return repo.setReaction(messageId, emoji);
      case Ok(:final value?):
        var result = await repo.setLockedReaction(
          messageId,
          value.ciphertext,
          value.olmType,
        );
        if (result case Err(failure: NetworkFailure(retryable: true))) {
          result = await repo.setLockedReaction(
            messageId,
            value.ciphertext,
            value.olmType,
          );
        }
        // Saved only once the server accepted these bytes: a failed try must not replace the earlier good copy or count as used.
        if (result is Ok<void>) {
          await ref
              .read(reactionOpenerProvider)
              .rememberOwn(messageId, me, value.ciphertext, emoji);
        }
        return result;
    }
  }

  /// Once, after the join: re-reads the reactions and merges them in. The
  /// fetched state wins for every message nothing newer touched; reactions
  /// applied while it was in flight are re-applied on top.
  Future<void> _reconcile(String conversationId, int generation) async {
    try {
      await future;
    } catch (_) {
      return; // the load failed; nothing to reconcile
    }
    if (generation != _generation) return;
    if (_since != null) {
      _rerun = true;
      return;
    }
    _since = [];
    final fetched = await ref
        .read(reactionRepositoryProvider)
        .reactions(conversationId);
    if (generation != _generation) return;
    final since = _since ?? const <Reaction>[];
    _since = null;
    if (fetched case Ok(:final value)) {
      state = AsyncData(
        since.fold<ReactionsByMessage>(groupReactions(value), applyReaction),
      );
    }
    if (_rerun && generation == _generation) {
      _rerun = false;
      await _reconcile(conversationId, generation);
    }
  }
}

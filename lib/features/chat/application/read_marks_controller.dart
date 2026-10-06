part of 'chat_controllers.dart';

/// How far the other members of the open conversation have read, live.
/// Empty when nothing is shared: messages then simply look normal. Rebuilt
/// when the member turns their own read status on or off.
final readMarksProvider =
    AsyncNotifierProvider.autoDispose<ReadMarksController, List<ReadMark>>(
      ReadMarksController.new,
      retry: _never,
    );

class ReadMarksController extends AsyncNotifier<List<ReadMark>> {
  // Reads that arrive while a load is on its way, applied once it lands.
  final _early = <ReadMark>[];

  @override
  Future<List<ReadMark>> build() async {
    _early.clear();
    final conversationId = ref.watch(openConversationProvider);
    ref.watch(currentUserIdProvider);
    ref.watch(ownProfileProvider.select((p) => p.value?.shareReadStatus));
    if (conversationId == null) return const [];
    // Watched: a group discovered to be one the member has left or been
    // removed from (leftConversationGuardProvider) rebuilds this at once and
    // leaves the reads:<id> channel, same reasoning as Typing.build() in
    // presence/application/presence_controllers.dart. The select folds
    // "not found yet / still loading" and "found, not left" to the same
    // `false` so the loading -> loaded transition does not itself count as
    // a change and resubscribe a second channel -- only an actual
    // left/removed flip does.
    final hasLeft = ref.watch(
      conversationListProvider.select(
        (s) =>
            (s.value ?? const <Conversation>[])
                .where((c) => c.id == conversationId)
                .firstOrNull
                ?.hasLeft ==
            true,
      ),
    );
    if (hasLeft) return const [];
    final repo = ref.read(chatRepositoryProvider);
    // Subscribed before the read, so a read in between is not lost; a
    // failed subscription only costs the live part.
    final updates = await repo.readUpdates(conversationId);
    if (updates case Ok(:final value)) {
      final sub = value.listen(_saw);
      ref.onDispose(sub.cancel);
    }
    // Delivery is a separate topic; a failed or slow join only costs the live
    // ticks, so the marks load without waiting for it. Events before the load
    // lands are buffered by _saw.
    // Per-build flag: the provider rebuilds (it is not disposed) when the chat
    // closes or another opens, so `ref.mounted` cannot tell a stale join.
    var live = true;
    ref.onDispose(() => live = false);
    unawaited(
      repo.deliveredUpdates(conversationId).then((delivered) {
        if (delivered case Ok(:final value)) {
          final sub = value.listen(_saw);
          if (live) {
            ref.onDispose(sub.cancel);
          } else {
            unawaited(sub.cancel());
          }
        }
      }),
    );
    final loaded = switch (await repo.readMarks(conversationId)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    return _early.fold<List<ReadMark>>(loaded, _merged);
  }

  void _saw(ReadMark mark) {
    final current = state.value;
    if (state.isLoading || current == null) {
      _early.add(mark);
      return;
    }
    state = AsyncData(_merged(current, mark));
  }

  static DateTime? _later(DateTime? a, DateTime? b) =>
      a == null ? b : (b == null || !b.isAfter(a) ? a : b);

  /// [marks] with [mark] applied: only a later read or delivery moves a
  /// member's marks.
  static List<ReadMark> _merged(List<ReadMark> marks, ReadMark mark) => [
    for (final m in marks)
      if (m.userId == mark.userId)
        m.copyWith(
          shares: mark.readAt != null ? true : m.shares,
          readAt: _later(m.readAt, mark.readAt),
          deliveredAt: _later(m.deliveredAt, mark.deliveredAt),
        )
      else
        m,
  ];
}

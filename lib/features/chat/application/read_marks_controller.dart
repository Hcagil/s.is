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
    _conversationId = conversationId;
    _shown = false;
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
    // Stored marks first (milliseconds, works offline); the server answer
    // replaces them when it lands.
    final stored = await _stored(conversationId);
    if (stored.isNotEmpty) {
      state = AsyncData(stored);
      _shown = true;
    }
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
    switch (await repo.readMarks(conversationId)) {
      case Ok(:final value):
        // The server answer replaces the stored list entirely, so a member who
        // stopped sharing loses the stored read time.
        final merged = _early.fold<List<ReadMark>>(value, _merged);
        unawaited(_save(conversationId, merged));
        _shown = true;
        return merged;
      case Err(:final failure):
        // Offline: keep the marks saved on the phone.
        if (stored.isEmpty) throw failure;
        _shown = true;
        return _early.fold<List<ReadMark>>(stored, _merged);
    }
  }

  String? _conversationId;
  bool _shown = false;

  Future<List<ReadMark>> _stored(String id) async {
    try {
      return await ref.read(readMarkStoreProvider).load(id);
    } catch (_) {
      return const []; // no store configured (tests) or it failed
    }
  }

  Future<void> _save(String id, List<ReadMark> marks) async {
    try {
      await ref.read(readMarkStoreProvider).save(id, marks);
    } catch (_) {}
  }

  void _saw(ReadMark mark) {
    _early.add(mark); // folded into the server answer when it lands
    final current = state.value;
    if (!_shown || current == null) return;
    final merged = _merged(current, mark);
    state = AsyncData(merged);
    if (_conversationId case final id?) unawaited(_save(id, merged));
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

part of 'chat_controllers.dart';

/// The chat list's own search box: every conversation the caller belongs to.
final class ChatListSearchState {
  const ChatListSearchState({
    this.query = '',
    this.results = const [],
    this.failure,
  });

  final String query;

  /// Hits across every conversation, newest first.
  final List<Message> results;

  /// The last search failure, if any -- for the screen to show as a notice
  /// while [results] stays whatever it was before. Cleared by the next
  /// search attempt, success or failure.
  final Failure? failure;
}

final chatListSearchProvider =
    NotifierProvider<ChatListSearchController, ChatListSearchState>(
      ChatListSearchController.new,
    );

class ChatListSearchController extends Notifier<ChatListSearchState> {
  Timer? _debounce;

  /// Bumped on every keystroke; a response is applied only when it is still
  /// the latest one asked for, so a slow answer to an old query can never
  /// overwrite a newer one still in flight.
  int _generation = 0;

  @override
  ChatListSearchState build() {
    // Fresh per account, like every other search/list here.
    ref.watch(currentUserIdProvider);
    // Invalidates any request already in flight for the previous account.
    _generation++;
    ref.onDispose(() => _debounce?.cancel());
    return const ChatListSearchState();
  }

  /// Debounces [query] ~300ms, then searches every conversation the caller
  /// belongs to. Fewer than three letters or digits -- including empty --
  /// clears the results at once, with no round trip.
  void search(String query) {
    _debounce?.cancel();
    if (!isSearchable(query)) {
      _generation++;
      state = const ChatListSearchState();
      return;
    }
    final generation = ++_generation;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      // The phone first: instant, and the only source once every chat is
      // fully stored; before that the server stays the fallback for older hits.
      final store = _storeOf(ref);
      var local = const <Message>[];
      if (store != null) {
        local = await store.search(query);
        final complete = await _allStored(store);
        if (!ref.mounted || generation != _generation) return;
        if (local.isNotEmpty || complete) {
          state = ChatListSearchState(query: query, results: local);
        }
        if (complete) return;
      }
      final result = await ref.read(chatRepositoryProvider).search(query);
      if (!ref.mounted || generation != _generation) return;
      switch (result) {
        case Ok(:final value):
          state = ChatListSearchState(
            query: query,
            results: _merged(local, value),
          );
        case Err(:final failure):
          // The list stays usable: only the failure is new, not the results.
          state = ChatListSearchState(
            query: query,
            results: state.results,
            failure: failure,
          );
      }
    });
  }

  /// True when every conversation on the list has its whole history stored.
  Future<bool> _allStored(MessageStore store) async {
    final chats = ref.read(conversationListProvider).value;
    if (chats == null || chats.isEmpty) return false;
    for (final c in chats) {
      if (!((await store.syncState(c.id))?.complete ?? false)) return false;
    }
    return true;
  }

  /// [local] and [server] merged by message id, newest first.
  static List<Message> _merged(List<Message> local, List<Message> server) {
    final seen = {for (final m in local) m.id};
    return [
      ...local,
      for (final m in server)
        if (seen.add(m.id)) m,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Clears the search box: back to the plain conversation list.
  void clear() => search('');
}

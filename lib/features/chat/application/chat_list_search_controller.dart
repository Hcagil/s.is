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
      final result = await ref.read(chatRepositoryProvider).search(query);
      if (!ref.mounted || generation != _generation) return;
      switch (result) {
        case Ok(:final value):
          state = ChatListSearchState(query: query, results: value);
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

  /// Clears the search box: back to the plain conversation list.
  void clear() => search('');
}

part of 'chat_controllers.dart';

/// Search inside the open conversation, and where the member is looking
/// among the hits.
final class ChatSearchState {
  const ChatSearchState({
    this.query = '',
    this.hits = const [],
    this.index = -1,
    this.serverAnswered = false,
    this.failure,
  });

  /// What was searched for; empty means the search box is closed.
  final String query;

  /// Hits in the open conversation, newest first: local-only until the
  /// server has answered, then the merged, authoritative set.
  final List<Message> hits;

  /// Which hit is current, or -1 when there are none (no search yet, or no
  /// match).
  final int index;

  /// Whether the server has answered for [query] in this conversation yet.
  /// Until then [hits] is only what this phone already has loaded, and may
  /// be incomplete -- the search bar shows a '+' and stepping past the
  /// oldest hit asks the server.
  final bool serverAnswered;

  /// A failure from asking the server while stepping past the oldest local
  /// hit -- the search bar shows it once, as a notice. Reset by the next
  /// state change (a new search, a move, a fresh answer); never set by
  /// [ChatSearchController.search] itself, whose own failure already goes
  /// straight back to its caller.
  final Failure? failure;

  Message? get current =>
      index >= 0 && index < hits.length ? hits[index] : null;
}

final chatSearchProvider =
    NotifierProvider<ChatSearchController, ChatSearchState>(
      ChatSearchController.new,
    );

/// In-chat search: instant from the messages already loaded on this phone,
/// the server asked only when there is nothing local to show, or when the
/// member steps past the oldest local hit looking for an older one. Jumping
/// between hits with next/previous is clamped at the ends -- it does not
/// wrap, so reaching the oldest or newest hit and asking for another simply
/// stays there (after asking the server once, for the oldest end).
class ChatSearchController extends Notifier<ChatSearchState> {
  @override
  ChatSearchState build() {
    // Closed whenever a different conversation opens.
    ref.watch(openConversationProvider);
    return const ChatSearchState();
  }

  /// Searches the open conversation for [query]. Hits already loaded on this
  /// phone (the open conversation's [messagesProvider] state) show at once,
  /// synchronously, before any round trip -- same fold and substring rule
  /// the server applies (see [foldSearch]), so a match here is a match
  /// there. The server is asked only when there is no local hit at all; the
  /// [Err] reason is then the caller's to show, same as
  /// [MessagesController.editMessage]. A local hit needs no round trip, so
  /// this only fails when the server had to be asked and refused.
  Future<Result<void>> search(String query) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    if (!isSearchable(query)) {
      state = ChatSearchState(query: query);
      return const Ok(null);
    }
    final messages = ref.read(messagesProvider.notifier);
    if (messages.isJumped) {
      // A new query is about the chat's current, live state -- not whatever
      // old window a previous hit jumped to. Go back to the newest 500 first
      // (same as closing search does), and wait for it: there is nothing
      // local to show from an old, replaced window.
      state = ChatSearchState(query: query);
      messages.returnToLive();
      await ref.read(messagesProvider.future);
      if (!ref.mounted ||
          ref.read(openConversationProvider) != conversationId ||
          state.query != query) {
        return const Ok(null);
      }
    }
    final local = _localHits(conversationId, query);
    state = ChatSearchState(
      query: query,
      hits: local,
      index: local.isEmpty ? -1 : 0,
    );
    if (local.isEmpty) {
      return _askServer(conversationId, query);
    }
    return const Ok(null);
  }

  /// Messages already loaded for [conversationId] whose body contains
  /// [query], newest first -- deleted/vanished and attachment-only (empty
  /// body) messages excluded, exactly what the server's own search excludes.
  /// [messagesProvider] keeps the previous conversation's list visible while
  /// a newly opened one is still loading, so [conversationId] is checked
  /// here too, not just at the call site -- otherwise a chat just left can
  /// answer for the one just opened.
  List<Message> _localHits(String conversationId, String query) {
    final loaded = ref.read(messagesProvider).value ?? const <Message>[];
    final folded = foldSearch(query);
    return [
      for (final m in loaded.reversed)
        if (m.conversationId == conversationId &&
            !m.isDeleted &&
            m.body.isNotEmpty &&
            foldSearch(m.body).contains(folded))
          m,
    ];
  }

  /// Asks the server for [query] in [conversationId] and merges its answer
  /// into [state.hits], de-duplicated by message id, newest first. Ignored
  /// when a newer search or a different conversation has since taken over --
  /// the same stale-answer guard [MessagesController.jumpToAround] uses.
  Future<Result<void>> _askServer(String conversationId, String query) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .search(query, conversationId: conversationId);
    if (result case Ok(:final value)
        when ref.mounted &&
            ref.read(openConversationProvider) == conversationId &&
            state.query == query) {
      final currentId = state.current?.id;
      final merged = _merge(state.hits, value);
      final restored = currentId == null
          ? -1
          : merged.indexWhere((m) => m.id == currentId);
      state = ChatSearchState(
        query: query,
        hits: merged,
        index: restored >= 0 ? restored : (merged.isEmpty ? -1 : 0),
        serverAnswered: true,
      );
    }
    return switch (result) {
      Ok() => const Ok(null),
      Err(:final failure) => Err(failure),
    };
  }

  /// [local] and [server] merged by message id, newest first.
  static List<Message> _merge(List<Message> local, List<Message> server) {
    final seen = {for (final m in local) m.id};
    final merged = [
      ...local,
      for (final m in server)
        if (seen.add(m.id)) m,
    ];
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }

  /// Closes the search: no query, no hits, nothing current.
  void close() => state = const ChatSearchState();

  /// Makes the hit with [messageId] current, when it is among [state.hits] --
  /// for opening a conversation already jumped to one particular result (the
  /// chat list's own search leads here). A no-op otherwise.
  void select(String messageId) {
    final index = state.hits.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    state = ChatSearchState(
      query: state.query,
      hits: state.hits,
      index: index,
      serverAnswered: state.serverAnswered,
    );
  }

  /// Moves toward an older hit (hits are newest first, so a higher index).
  /// Already on the oldest local hit and the server has not answered for
  /// this query yet: asks it first, in case it holds an older one, then
  /// moves on if it did.
  void next() {
    if (state.hits.isEmpty) return;
    if (state.index >= state.hits.length - 1 && !state.serverAnswered) {
      unawaited(_stepPastOldest());
      return;
    }
    _move(1);
  }

  /// Moves toward a newer hit (a lower index).
  void previous() => _move(-1);

  void _move(int delta) {
    if (state.hits.isEmpty) return;
    state = ChatSearchState(
      query: state.query,
      hits: state.hits,
      index: (state.index + delta).clamp(0, state.hits.length - 1),
      serverAnswered: state.serverAnswered,
    );
  }

  Future<void> _stepPastOldest() async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return;
    final query = state.query;
    final before = state.hits.length;
    final result = await _askServer(conversationId, query);
    if (!ref.mounted ||
        ref.read(openConversationProvider) != conversationId ||
        state.query != query) {
      return;
    }
    if (result case Err(:final failure)) {
      // Unlike search()'s own failure, nothing awaits this call directly
      // (next() is fire-and-forget) -- carried in state instead, for the
      // search bar to show as a notice. Hits/index/serverAnswered are left
      // exactly as they were: a failed step forward is not an answer.
      state = ChatSearchState(
        query: state.query,
        hits: state.hits,
        index: state.index,
        serverAnswered: state.serverAnswered,
        failure: failure,
      );
      return;
    }
    if (state.hits.length > before) _move(1);
  }
}

// A ReactionRepository stand-in written from the interface
// (lib/features/chat/domain/reaction_repository.dart) and the server
// contract (supabase/migrations/20261005140000_message_reactions.sql), never
// from the implementation. It behaves like the real one where that is
// inconvenient:
//  * every answer is asynchronous (never synchronous), and each kind of call
//    can be held open by a hook so a test decides the order things land in;
//  * the Realtime join resolves later than the call (onJoin), and events can
//    arrive before the first load answers;
//  * a set the server accepts echoes back on the live stream, the caller's
//    own included, like postgres_changes does;
//  * a removal arrives as a null emoji, never a delete;
//  * a signed-out caller is refused (DeniedFailure).
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/reaction_repository.dart';

class ReactionFake implements ReactionRepository {
  ReactionFake({this.me = 'u1', Map<String, String>? conversationOf})
    : conversationOf = conversationOf ?? {};

  /// The signed-in user; null = signed out.
  String? me;

  /// Which conversation a message belongs to; unknown messages are in 'c1'.
  final Map<String, String> conversationOf;
  String _cid(String messageId) => conversationOf[messageId] ?? 'c1';

  /// The server's rows per conversation, newest change first; emoji never
  /// null here (a cleared row is not listed by reactions()).
  final server = <String, List<Reaction>>{};

  /// The caller's own reaction history, newest first (for usage).
  final _history = <String>[];

  void seed(String conversationId, List<Reaction> rows) =>
      server[conversationId] = [...rows];

  // ---- reactions() ----
  final loadCalls = <String>[];

  /// When set, decides the answer of the [n]th (1-based) load of a
  /// conversation; the default answers the server's rows after a turn.
  Future<Result<List<Reaction>>> Function(String conversationId, int n)? onLoad;

  int loadsOf(String conversationId) =>
      loadCalls.where((c) => c == conversationId).length;

  Result<List<Reaction>> snapshot(String conversationId) =>
      Ok(List.unmodifiable(server[conversationId] ?? const <Reaction>[]));

  @override
  Future<Result<List<Reaction>>> reactions(String conversationId) async {
    loadCalls.add(conversationId);
    final n = loadsOf(conversationId);
    final hook = onLoad;
    if (hook != null) return hook(conversationId, n);
    await Future<void>.delayed(Duration.zero);
    if (me == null) return const Err(DeniedFailure());
    return snapshot(conversationId);
  }

  // ---- setReaction() ----
  final setCalls = <(String, String?)>[];

  /// When set, answers setReaction instead of the server rules below.
  Future<Result<void>> Function(String messageId, String? emoji)? onSet;

  @override
  Future<Result<void>> setReaction(String messageId, String? emoji) async {
    setCalls.add((messageId, emoji));
    final hook = onSet;
    if (hook != null) return hook(messageId, emoji);
    await Future<void>.delayed(Duration.zero);
    return serverSet(messageId, emoji);
  }

  /// What the server does for an accepted set: stores it and publishes it.
  Result<void> serverSet(String messageId, String? emoji) {
    final user = me;
    if (user == null) return const Err(DeniedFailure());
    final cid = _cid(messageId);
    final rows = server.putIfAbsent(cid, () => [])
      ..removeWhere((r) => r.messageId == messageId && r.userId == user);
    final r = Reaction(messageId: messageId, userId: user, emoji: emoji);
    if (emoji != null) {
      rows.insert(0, r);
      _history.insert(0, emoji);
    }
    _publish(cid, r);
    return const Ok(null);
  }

  // ---- reactionUpdates() ----
  final joinCalls = <String>[];

  /// When set, the join for a conversation resolves only once this does.
  Future<void> Function(String conversationId)? onJoin;

  /// When set, the join answers this instead of a stream.
  Failure? joinFailure;

  final _channels = <String, List<StreamController<Reaction>>>{};
  int listens = 0;
  int cancels = 0;

  /// Subscriptions with a listener still attached, per conversation.
  int listeners(String conversationId) =>
      (_channels[conversationId] ?? []).where((c) => c.hasListener).length;

  @override
  Future<Result<Stream<Reaction>>> reactionUpdates(
    String conversationId,
  ) async {
    joinCalls.add(conversationId);
    final hook = onJoin;
    if (hook != null) {
      await hook(conversationId);
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    final failure = joinFailure;
    if (failure != null) return Err(failure);
    // Broadcast, like a Realtime callback: an event with no listener yet is
    // gone, so a client that buffers early events must listen at the join.
    final controller = StreamController<Reaction>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    _channels.putIfAbsent(conversationId, () => []).add(controller);
    return Ok(controller.stream);
  }

  void _publish(String conversationId, Reaction r) {
    for (final c in _channels[conversationId] ?? const []) {
      if (!c.isClosed) c.add(r);
    }
  }

  /// Another member's change, as the server stores and publishes it.
  void others(String conversationId, Reaction r) {
    final rows = server.putIfAbsent(conversationId, () => [])
      ..removeWhere((x) => x.messageId == r.messageId && x.userId == r.userId);
    if (r.emoji != null) rows.insert(0, r);
    _publish(conversationId, r);
  }

  /// An event on the live feed only (the server rows are not changed).
  void emit(String conversationId, Reaction r) => _publish(conversationId, r);

  // ---- myReactionUsage() ----
  int usageCalls = 0;

  @override
  Future<Result<Map<String, int>>> myReactionUsage() async {
    usageCalls++;
    await Future<void>.delayed(Duration.zero);
    if (me == null) return const Err(DeniedFailure());
    final counts = <String, int>{};
    for (final e in _history.take(300)) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    return Ok(counts);
  }
}

// A PollRepository stand-in written from the interface
// (lib/features/chat/domain/poll_repository.dart) and the server contract
// (create_poll / vote_poll / close_poll), never from the implementation. It
// behaves like the real one where that is inconvenient:
//  * every answer is asynchronous, and each kind of call can be held open by
//    a hook so a test decides the order things land in;
//  * the Realtime join resolves later than the call (onJoin) and is a
//    broadcast stream: an event with no listener yet is gone;
//  * an accepted vote / close is published on the live stream (counts and
//    closed only, never who voted), the caller's own included;
//  * a vote on a closed poll is Err(PollClosedFailure), a close by anyone but
//    the creator Err(DeniedFailure), a signed-out caller Err(DeniedFailure);
//  * voters() of an anonymous poll lists only the caller's own votes.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/poll.dart';
import 'package:sis/features/chat/domain/poll_repository.dart';

class PollFake implements PollRepository {
  PollFake({this.me = 'u1'});

  /// The signed-in user; null = signed out.
  String? me;

  /// Server state: conversation of each poll, its creator, the poll head and
  /// options (counts derived from [votes]).
  final conversationOf = <String, String>{};
  final creatorOf = <String, String>{};
  final heads = <String, Poll>{};

  /// messageId -> userId -> chosen option ids.
  final votes = <String, Map<String, Set<String>>>{};

  /// Puts a poll on the server, as [creator] made it, with [ballots]
  /// (userId -> options) already cast.
  void seed(
    String conversationId,
    Poll poll, {
    String creator = 'u2',
    Map<String, Set<String>> ballots = const {},
  }) {
    conversationOf[poll.messageId] = conversationId;
    creatorOf[poll.messageId] = creator;
    heads[poll.messageId] = poll;
    votes[poll.messageId] = {
      for (final e in ballots.entries) e.key: {...e.value},
    };
  }

  /// The poll as [user] reads it from the server right now.
  Poll? view(String messageId, [String? user]) {
    final head = heads[messageId];
    if (head == null) return null;
    final ballots = votes[messageId] ?? const {};
    return Poll(
      messageId: head.messageId,
      question: head.question,
      options: [
        for (final o in head.options)
          PollOption(
            id: o.id,
            text: o.text,
            votes: ballots.values.where((s) => s.contains(o.id)).length,
          ),
      ],
      multiple: head.multiple,
      anonymous: head.anonymous,
      closed: head.closed,
      voters: ballots.values.where((s) => s.isNotEmpty).length,
      mine: {...?ballots[user ?? me]},
    );
  }

  // ---- polls() / poll() ----
  final loadCalls = <String>[];
  final pollCalls = <String>[];

  /// When set, answers polls() instead of the server rows.
  Future<Result<List<Poll>>> Function(String conversationId, int n)? onLoad;

  /// When set, answers poll() instead of the server row.
  Future<Result<Poll?>> Function(String messageId)? onPoll;

  @override
  Future<Result<List<Poll>>> polls(String conversationId) async {
    loadCalls.add(conversationId);
    final hook = onLoad;
    if (hook != null) {
      return hook(
        conversationId,
        loadCalls.where((c) => c == conversationId).length,
      );
    }
    await Future<void>.delayed(Duration.zero);
    if (me == null) return const Err(DeniedFailure());
    return Ok([
      for (final e in conversationOf.entries)
        if (e.value == conversationId) view(e.key)!,
    ]);
  }

  @override
  Future<Result<Poll?>> poll(String messageId) async {
    pollCalls.add(messageId);
    final hook = onPoll;
    if (hook != null) return hook(messageId);
    await Future<void>.delayed(Duration.zero);
    if (me == null) return const Err(DeniedFailure());
    return Ok(view(messageId));
  }

  // ---- createPoll() ----
  final createCalls = <(String, String, PollDraft)>[];

  /// When set, answers createPoll instead of the server rules.
  Future<Result<void>> Function(String cid, String mid, PollDraft d)? onCreate;

  /// Option ids the server gives a created poll: `messageId-o<i>`.
  @override
  Future<Result<void>> createPoll(
    String conversationId,
    String messageId,
    PollDraft draft,
  ) async {
    createCalls.add((conversationId, messageId, draft));
    final hook = onCreate;
    if (hook != null) return hook(conversationId, messageId, draft);
    await Future<void>.delayed(Duration.zero);
    final user = me;
    if (user == null) return const Err(DeniedFailure());
    if (heads.containsKey(messageId)) return const Ok(null);
    seed(
      conversationId,
      Poll(
        messageId: messageId,
        question: draft.question,
        options: [
          for (var i = 0; i < draft.options.length; i++)
            PollOption(id: '$messageId-o$i', text: draft.options[i], votes: 0),
        ],
        multiple: draft.multiple,
        anonymous: draft.anonymous,
        closed: false,
        voters: 0,
      ),
      creator: user,
    );
    return const Ok(null);
  }

  // ---- vote() ----
  final voteCalls = <(String, Set<String>)>[];

  /// When set, answers vote instead of the server rules below.
  Future<Result<void>> Function(String messageId, Set<String> options)? onVote;

  @override
  Future<Result<void>> vote(String messageId, Set<String> optionIds) async {
    voteCalls.add((messageId, {...optionIds}));
    final hook = onVote;
    if (hook != null) return hook(messageId, optionIds);
    await Future<void>.delayed(Duration.zero);
    return serverVote(messageId, optionIds);
  }

  /// What the server does with a vote by [user] (default: me).
  Result<void> serverVote(
    String messageId,
    Set<String> optionIds, [
    String? user,
  ]) {
    final who = user ?? me;
    final head = heads[messageId];
    if (who == null || head == null) return const Err(DeniedFailure());
    if (head.closed) return const Err(PollClosedFailure());
    final before = view(messageId)!;
    votes[messageId]![who] = {...optionIds};
    _publishDiff(before, view(messageId)!);
    return const Ok(null);
  }

  // ---- close() ----
  final closeCalls = <String>[];

  /// When set, answers close instead of the server rules below.
  Future<Result<void>> Function(String messageId)? onClose;

  @override
  Future<Result<void>> close(String messageId) async {
    closeCalls.add(messageId);
    final hook = onClose;
    if (hook != null) return hook(messageId);
    await Future<void>.delayed(Duration.zero);
    return serverClose(messageId);
  }

  /// What the server does with a close by [user] (default: me).
  Result<void> serverClose(String messageId, [String? user]) {
    final who = user ?? me;
    final head = heads[messageId];
    if (who == null || head == null || creatorOf[messageId] != who) {
      return const Err(DeniedFailure());
    }
    if (head.closed) return const Ok(null);
    heads[messageId] = head.copyWith(closed: true);
    final v = view(messageId)!;
    _publish(
      conversationOf[messageId]!,
      PollHeadChange(messageId, v.voters, true),
    );
    return const Ok(null);
  }

  // ---- voters() ----
  final votersCalls = <String>[];

  /// When set, answers voters instead of the server rows.
  Future<Result<List<PollVote>>> Function(String messageId)? onVoters;

  @override
  Future<Result<List<PollVote>>> voters(String messageId) async {
    votersCalls.add(messageId);
    final hook = onVoters;
    if (hook != null) return hook(messageId);
    await Future<void>.delayed(Duration.zero);
    final user = me;
    final head = heads[messageId];
    if (user == null) return const Err(DeniedFailure());
    if (head == null) return const Ok([]);
    return Ok([
      for (final e in (votes[messageId] ?? const {}).entries)
        if (!head.anonymous || e.key == user)
          for (final o in e.value)
            PollVote(messageId: messageId, optionId: o, userId: e.key),
    ]);
  }

  // ---- pollUpdates() ----
  final joinCalls = <String>[];

  /// When set, the join for a conversation resolves only once this does.
  Future<void> Function(String conversationId)? onJoin;

  /// When set, the join answers this instead of a stream.
  Failure? joinFailure;

  final _channels = <String, List<StreamController<PollChange>>>{};

  int listeners(String conversationId) =>
      (_channels[conversationId] ?? []).where((c) => c.hasListener).length;

  @override
  Future<Result<Stream<PollChange>>> pollUpdates(String conversationId) async {
    joinCalls.add(conversationId);
    final hook = onJoin;
    if (hook != null) {
      await hook(conversationId);
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    final failure = joinFailure;
    if (failure != null) return Err(failure);
    final controller = StreamController<PollChange>.broadcast();
    _channels.putIfAbsent(conversationId, () => []).add(controller);
    return Ok(controller.stream);
  }

  void _publishDiff(Poll before, Poll after) {
    final cid = conversationOf[after.messageId]!;
    for (var i = 0; i < after.options.length; i++) {
      if (after.options[i].votes != before.options[i].votes) {
        _publish(
          cid,
          PollOptionChange(
            after.messageId,
            after.options[i].id,
            after.options[i].votes,
          ),
        );
      }
    }
    if (after.voters != before.voters) {
      _publish(
        cid,
        PollHeadChange(after.messageId, after.voters, after.closed),
      );
    }
  }

  void _publish(String conversationId, PollChange change) {
    for (final c in _channels[conversationId] ?? const []) {
      if (!c.isClosed) c.add(change);
    }
  }

  /// Another member [user] votes, as the server stores and publishes it.
  Result<void> others(String messageId, String user, Set<String> options) =>
      serverVote(messageId, options, user);

  /// An event on the live feed only (server state unchanged).
  void emit(String conversationId, PollChange change) =>
      _publish(conversationId, change);
}

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../../../data/realtime_channels.dart';
import '../domain/poll.dart';
import '../domain/poll_repository.dart';

/// [PollRepository] backed by Supabase Postgres and Realtime.
///
/// Row-level security decides what any of these queries return; nothing here
/// filters for authorisation. A refusal arrives as a [PostgrestException] with
/// SQLSTATE 55000 (closed) or 42501 (denied) and is reported as [PollClosedFailure]
/// or [DeniedFailure].
final class SupabasePollRepository implements PollRepository {
  SupabasePollRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '55000' =>
      const PollClosedFailure(),
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<List<Poll>>> polls(String conversationId) async {
    try {
      final rows = await _client
          .from('polls')
          .select(
            'message_id, question, multiple, anonymous, voter_count, closed_at, poll_options(id, position, text, vote_count)',
          )
          .eq('conversation_id', conversationId)
          .order('created_at', ascending: false)
          .limit(200)
          .retriedOnce();
      final uid = _uid;
      Map<String, Set<String>> mine = const <String, Set<String>>{};
      if (uid != null) {
        final voteRows = await _client
            .from('poll_votes')
            .select('message_id, option_id')
            .eq('conversation_id', conversationId)
            .eq('user_id', uid)
            .limit(1000)
            .retriedOnce();
        final votesByMessage = <String, Set<String>>{};
        for (final r in voteRows) {
          final msgId = r['message_id'] as String;
          final optionId = r['option_id'] as String;
          votesByMessage.putIfAbsent(msgId, () => <String>{}).add(optionId);
        }
        mine = votesByMessage;
      }
      return Ok([
        for (final row in rows)
          _toPoll(row, mine[row['message_id']] ?? const <String>{}),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Poll?>> poll(String messageId) async {
    try {
      final row = await _client
          .from('polls')
          .select(
            'message_id, question, multiple, anonymous, voter_count, closed_at, poll_options(id, position, text, vote_count)',
          )
          .eq('message_id', messageId)
          .maybeSingle()
          .retriedOnce();
      if (row == null) return const Ok(null);

      final uid = _uid;
      Set<String> mine = const <String>{};
      if (uid != null) {
        final voteRows = await _client
            .from('poll_votes')
            .select('option_id')
            .eq('message_id', messageId)
            .eq('user_id', uid)
            .limit(1000)
            .retriedOnce();
        mine = Set<String>.of(voteRows.map((r) => r['option_id'] as String));
      }

      return Ok(_toPoll(row, mine));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  static Poll _toPoll(Map<String, dynamic> row, Set<String> mine) {
    final raw = [...(row['poll_options'] as List)]
      ..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
    final options = [
      for (final o in raw)
        PollOption(
          id: o['id'] as String,
          text: o['text'] as String,
          votes: o['vote_count'] as int,
        ),
    ];
    return Poll(
      messageId: row['message_id'] as String,
      question: row['question'] as String,
      options: options,
      multiple: row['multiple'] as bool,
      anonymous: row['anonymous'] as bool,
      closed: row['closed_at'] != null,
      voters: row['voter_count'] as int,
      mine: mine,
    );
  }

  @override
  Future<Result<void>> createPoll(
    String conversationId,
    String messageId,
    PollDraft draft,
  ) async {
    try {
      await _client.rpc(
        'create_poll',
        params: {
          'p_conversation': conversationId,
          'p_id': messageId,
          'p_question': draft.question.trim(),
          'p_options': cleanPollOptions(draft.options),
          'p_multiple': draft.multiple,
          'p_anonymous': draft.anonymous,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> vote(String messageId, Set<String> optionIds) async {
    try {
      await _client.rpc(
        'vote_poll',
        params: {'p_message': messageId, 'p_options': optionIds.toList()},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> close(String messageId) async {
    try {
      await _client.rpc('close_poll', params: {'p_message': messageId});
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<PollVote>>> voters(String messageId) async {
    try {
      final rows = await _client
          .from('poll_votes')
          .select('message_id, option_id, user_id')
          .eq('message_id', messageId)
          .order('created_at')
          .limit(1000)
          .retriedOnce();
      return Ok([
        for (final r in rows)
          PollVote(
            messageId: r['message_id'] as String,
            optionId: r['option_id'] as String,
            userId: r['user_id'] as String,
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<PollChange>>> pollUpdates(String conversationId) async {
    // postgres_changes, never broadcast: a broadcast skips RLS.
    final channel = _client.channel('polls:$conversationId');
    final controller = StreamController<PollChange>();
    PostgresChangeFilter inChat() => PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    );
    // poll_votes is never published: who voted must not travel live
    // (anonymous polls). Only the counts below do.
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'polls',
      filter: inChat(),
      callback: (payload) {
        if (controller.isClosed) return;
        final row = payload.newRecord;
        // An event the server could not authorise carries no row.
        if (row['message_id'] == null) return;
        controller.add(
          PollHeadChange(
            row['message_id'] as String,
            row['voter_count'] as int,
            row['closed_at'] != null,
          ),
        );
      },
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'poll_options',
      filter: inChat(),
      callback: (payload) {
        if (controller.isClosed) return;
        final row = payload.newRecord;
        if (row['message_id'] == null || row['id'] == null) return;
        controller.add(
          PollOptionChange(
            row['message_id'] as String,
            row['id'] as String,
            row['vote_count'] as int,
          ),
        );
      },
    );
    controller.onCancel = () => leaveChannel(_client, channel);
    try {
      await joinChannel(channel);
    } catch (e) {
      leaveChannel(_client, channel, controller);
      return Err(_asFailure(e));
    }
    return Ok(controller.stream);
  }
}

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../../../data/realtime_channels.dart';
import '../domain/reaction.dart';
import '../domain/reaction_repository.dart';

/// [ReactionRepository] backed by Supabase Postgres and Realtime.
///
/// Row-level security decides what any of these queries return; nothing here
/// filters for authorisation. A refusal arrives as a [PostgrestException] with
/// SQLSTATE 42501 and is reported as [DeniedFailure].
final class SupabaseReactionRepository implements ReactionRepository {
  SupabaseReactionRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<List<Reaction>>> reactions(String conversationId) async {
    try {
      final rows = await _client
          .from('message_reactions')
          .select('message_id, user_id, emoji')
          .eq('conversation_id', conversationId)
          .not('emoji', 'is', null)
          .order('updated_at', ascending: false)
          .limit(1000)
          .retriedOnce();
      return Ok([
        for (final r in rows)
          Reaction(
            messageId: r['message_id'] as String,
            userId: r['user_id'] as String,
            emoji: r['emoji'] as String?,
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> setReaction(String messageId, String? emoji) async {
    try {
      await _client.rpc(
        'set_reaction',
        params: {'message': messageId, 'emoji': emoji},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Map<String, int>>> myReactionUsage() async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      final rows = await _client
          .from('message_reactions')
          .select('emoji')
          .eq('user_id', uid)
          .not('emoji', 'is', null)
          .order('updated_at', ascending: false)
          .limit(300)
          .retriedOnce();
      final map = <String, int>{};
      for (final r in rows) {
        final emoji = r['emoji'] as String;
        map[emoji] = (map[emoji] ?? 0) + 1;
      }
      return Ok(map);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<Reaction>>> reactionUpdates(
    String conversationId,
  ) async {
    // postgres_changes, never broadcast: a broadcast skips RLS.
    final channel = _client.channel('reactions:$conversationId');
    final controller = StreamController<Reaction>();
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'message_reactions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'conversation_id',
        value: conversationId,
      ),
      callback: (payload) {
        if (controller.isClosed) return;
        final row = payload.newRecord;
        // An event the server could not authorise carries no row: nothing to
        // show, and a throw here would escape the Realtime client.
        if (row['message_id'] == null) return;
        // A removal is an update whose emoji is null (the publication carries
        // no deletes); it is passed on as such.
        controller.add(
          Reaction(
            messageId: row['message_id'] as String,
            userId: row['user_id'] as String,
            emoji: row['emoji'] as String?,
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

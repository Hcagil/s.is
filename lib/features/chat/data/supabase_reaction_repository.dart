import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../../../data/realtime_channels.dart';
import '../domain/reaction.dart';
import '../domain/reaction_opener.dart';
import '../domain/reaction_repository.dart';

/// [ReactionRepository] backed by Supabase Postgres and Realtime.
///
/// Row-level security decides what any of these queries return; nothing here
/// filters for authorisation. A refusal arrives as a [PostgrestException] with
/// SQLSTATE 42501 and is reported as [DeniedFailure].
///
/// Locked reactions (ciphertext rows) go through [opener] before anything
/// shows them; without one they are hidden.
final class SupabaseReactionRepository
    implements ReactionRepository, ReactionRelocker {
  SupabaseReactionRepository(this._client, {this._opener});

  final SupabaseClient _client;
  final ReactionOpener? _opener;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  Reaction _row(Map<String, dynamic> r) => Reaction(
    messageId: r['message_id'] as String,
    userId: r['user_id'] as String,
    emoji: r['emoji'] as String?,
    ciphertext: r['ciphertext'] as String?,
    olmType: (r['olm_type'] as num?)?.toInt(),
    updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
  );

  // Without an opener a locked row is hidden (emoji null), never dropped: a
  // live event for it must still remove the chip it replaces.
  Future<List<Reaction>> _opened(List<Reaction> rows) async {
    final opener = _opener;
    if (opener != null) return opener.open(rows);
    return [
      for (final r in rows)
        r.ciphertext == null
            ? r
            : Reaction(
                messageId: r.messageId,
                userId: r.userId,
                emoji: null,
                updatedAt: r.updatedAt,
              ),
    ];
  }

  @override
  Future<Result<List<Reaction>>> reactions(String conversationId) async {
    try {
      final rows = await _client
          .from('message_reactions')
          .select(
            'message_id, user_id, emoji, ciphertext, olm_type, updated_at',
          )
          .eq('conversation_id', conversationId)
          .or('emoji.not.is.null,ciphertext.not.is.null')
          .order('updated_at', ascending: false)
          .limit(1000)
          .retriedOnce();
      final opened = await _opened([for (final r in rows) _row(r)]);
      return Ok([
        for (final r in opened)
          if (r.emoji != null) r,
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
  Future<Result<void>> setLockedReaction(
    String messageId,
    String ciphertext,
    int olmType,
  ) async {
    try {
      await _client.rpc(
        'set_reaction_encrypted',
        params: {
          'message': messageId,
          'ciphertext': ciphertext,
          'olm_type': olmType,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<bool>> relockPlain(
    String messageId,
    String ciphertext,
    int olmType,
  ) async {
    try {
      final done = await _client.rpc(
        'relock_reaction',
        params: {
          'message': messageId,
          'ciphertext': ciphertext,
          'olm_type': olmType,
        },
      );
      return Ok(done == true);
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
      // Locked reactions: the server cannot count them, this phone does.
      final local = await _opener?.ownUsage(uid) ?? const <String, int>{};
      for (final e in local.entries) {
        map[e.key] = (map[e.key] ?? 0) + e.value;
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
        // A removal is an update whose emoji and ciphertext are null (the
        // publication carries no deletes); it is passed on as such. A locked
        // row is opened first; one that cannot be opened arrives as a removal.
        unawaited(
          _opened([_row(row)]).then((opened) {
            if (controller.isClosed) return;
            opened.forEach(controller.add);
          }),
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

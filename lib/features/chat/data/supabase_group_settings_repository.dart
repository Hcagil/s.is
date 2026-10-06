import 'dart:async';
import 'dart:developer';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/realtime_channels.dart';
import '../domain/group_event.dart';
import '../domain/group_settings_repository.dart';

/// [GroupSettingsRepository] backed by Supabase Postgres and Realtime.
final class SupabaseGroupSettingsRepository implements GroupSettingsRepository {
  SupabaseGroupSettingsRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<void>> setSettings(
    String conversationId, {
    bool? membersCanSetAvatar,
    bool? membersCanAdd,
    bool? newMembersSeeHistory,
  }) async {
    try {
      await _client.rpc(
        'set_group_settings',
        params: {
          'conversation': conversationId,
          'members_can_set_avatar': membersCanSetAvatar,
          'members_can_add': membersCanAdd,
          'new_members_see_history': newMembersSeeHistory,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> deleteGroup(String conversationId) async {
    try {
      final paths = await _client.rpc(
        'delete_group',
        params: {'conversation': conversationId},
      );
      if (paths is List && paths.isNotEmpty) {
        try {
          await _client.storage
              .from('attachments')
              .remove(List<String>.from(paths));
        } catch (e) {
          log(
            'deleteGroup: photo file removal failed: ${e.runtimeType}',
            name: 'sis.data',
            level: 900,
          );
        }
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<GroupEvent>>> pictureEvents(String conversationId) async {
    try {
      final rows = await _client.rpc(
        'group_picture_events',
        params: {'conversation': conversationId},
      );
      return Ok([
        for (final row in (rows as List).cast<Map<String, dynamic>>())
          GroupEvent(
            id: row['id'] as String,
            conversationId: row['conversation_id'] as String,
            kind: GroupEventKind.picture,
            subjectId: (row['actor_id'] as String?) ?? '',
            actorId: row['actor_id'] as String?,
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<Stream<GroupChange>>> groupChanges() async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    final channel = _client.channel(
      'chats:$uid',
      opts: const RealtimeChannelConfig(private: true),
    );
    final controller = StreamController<GroupChange>();
    channel.onBroadcast(
      event: 'group_changed',
      callback: (payload) {
        final body = payload['payload'];
        if (body is! Map) return;
        final id = body['conversation_id'];
        final what = body['what'];
        if (id is String && what is String && !controller.isClosed) {
          controller.add((conversationId: id, what: what));
        }
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

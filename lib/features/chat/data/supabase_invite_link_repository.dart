import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/group_event.dart';
import '../domain/invite_link.dart';

/// [InviteLinkRepository] backed by the invite functions in Supabase Postgres.
final class SupabaseInviteLinkRepository implements InviteLinkRepository {
  SupabaseInviteLinkRepository(this._client);

  final SupabaseClient _client;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    PostgrestException(:final code) when code == 'RLMT1' =>
      const SearchLimitFailure(),
    PostgrestException(:final code) when code == 'LINK1' =>
      const InviteLinkFailure(InviteLinkProblem.invalid),
    PostgrestException(:final code) when code == 'LINK2' =>
      const InviteLinkFailure(InviteLinkProblem.expired),
    PostgrestException(:final code) when code == 'LINK3' =>
      const InviteLinkFailure(InviteLinkProblem.closed),
    PostgrestException(:final code) when code == 'LINK4' =>
      const InviteLinkFailure(InviteLinkProblem.removed),
    _ => readableFailure(e),
  };

  InviteLink _inviteLinkFrom(Map<String, dynamic> row) => InviteLink(
    token: row['token'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
    expiresAt: row['expires_at'] != null
        ? DateTime.parse(row['expires_at'] as String)
        : null,
    validDays: row['limit_days'] as int?,
  );

  /// preview_invite_link and join_by_link return their refusal in an `error` column (LINK1..LINK4; null = fine) so the server counts the try.
  Failure? _linkRefusal(String? code) => switch (code) {
    null => null,
    'LINK2' => const InviteLinkFailure(InviteLinkProblem.expired),
    'LINK3' => const InviteLinkFailure(InviteLinkProblem.closed),
    'LINK4' => const InviteLinkFailure(InviteLinkProblem.removed),
    _ => const InviteLinkFailure(InviteLinkProblem.invalid),
  };

  @override
  Future<Result<InviteLink?>> inviteLink(String conversationId) async {
    try {
      final rows = await _client.rpc(
        'get_invite_link',
        params: {'conversation': conversationId},
      );
      if ((rows as List).isEmpty) {
        return const Ok(null);
      }
      final row = rows.cast<Map<String, dynamic>>().first;
      return Ok(_inviteLinkFrom(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<InviteLink>> resetInviteLink(
    String conversationId, {
    int? validDays,
  }) async {
    try {
      final rows = await _client.rpc(
        'reset_invite_link',
        params: {'conversation': conversationId, 'valid_days': validDays},
      );
      final row = (rows as List).cast<Map<String, dynamic>>().first;
      return Ok(_inviteLinkFrom(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<InviteLink>> setInviteLinkExpiry(
    String conversationId, {
    int? validDays,
  }) async {
    try {
      final rows = await _client.rpc(
        'set_invite_link_expiry',
        params: {'conversation': conversationId, 'valid_days': validDays},
      );
      final row = (rows as List).cast<Map<String, dynamic>>().first;
      return Ok(_inviteLinkFrom(row));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> turnOffInviteLink(String conversationId) async {
    try {
      await _client.rpc(
        'turn_off_invite_link',
        params: {'conversation': conversationId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<InvitePreview>> previewInvite(String code) async {
    try {
      final rows = await _client.rpc(
        'preview_invite_link',
        params: {'token': code},
      );
      final row = (rows as List).cast<Map<String, dynamic>>().first;
      final refused = _linkRefusal(row['error'] as String?);
      if (refused != null) return Err(refused);
      return Ok(
        InvitePreview(
          conversationId: row['conversation_id'] as String,
          title: row['title'] as String,
          memberCount: row['member_count'] as int,
          avatarPath: row['avatar_path'] as String?,
          newMembersSeeHistory: row['new_members_see_history'] as bool?,
        ),
      );
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<String>> joinByInvite(String code) async {
    try {
      final rows = await _client.rpc('join_by_link', params: {'token': code});
      final row = (rows as List).cast<Map<String, dynamic>>().first;
      final refused = _linkRefusal(row['error'] as String?);
      if (refused != null) return Err(refused);
      return Ok(row['conversation_id'] as String);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<GroupEvent>>> joinEvents(String conversationId) async {
    try {
      final rows = await _client.rpc(
        'group_join_events',
        params: {'conversation': conversationId},
      );
      return Ok([
        for (final row in (rows as List).cast<Map<String, dynamic>>())
          GroupEvent(
            id: row['id'] as String,
            conversationId: row['conversation_id'] as String,
            kind: GroupEventKind.joined,
            subjectId: (row['actor_id'] as String?) ?? '',
            actorId: row['actor_id'] as String?,
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
      ]);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}

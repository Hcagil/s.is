import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/invite_link.dart';

/// [InviteLinkRepository] behaving like the server: the caller's
/// invite link state, latency on every call, and a [calls] log.
class InviteLinkFake implements InviteLinkRepository {
  InviteLinkFake({this.latency = const Duration(milliseconds: 40)});

  final Duration latency;

  /// Conversations where the caller is an admin.
  final admins = <String>{};

  /// Conversations that are closed.
  final closedGroups = <String>{};

  /// Conversations the caller was removed from.
  final removedFrom = <String>{};

  /// Member count per conversation, default 2.
  final members = <String, int>{};

  /// Title per conversation, default 'Team'.
  final titles = <String, String>{};

  /// Conversations the caller has joined via invite.
  final joined = <String>[];

  /// Log of every call.
  final calls = <String>[];

  /// When set, the next call answers this instead of the server's own rule.
  Failure? failNext;

  /// Stored invite links per conversation.
  final _links = <String, InviteLink>{};

  int _n = 0;

  Future<void> _wait() async {
    await Future<void>.delayed(latency);
  }

  @override
  Future<Result<InviteLink?>> inviteLink(String conversationId) async {
    calls.add('get:$conversationId');
    await _wait();
    if (failNext != null) {
      final f = failNext!;
      failNext = null;
      return Err(f);
    }
    if (!admins.contains(conversationId)) return const Err(DeniedFailure());
    return Ok(_links[conversationId]);
  }

  @override
  Future<Result<InviteLink>> resetInviteLink(
    String conversationId, {
    int? validDays,
  }) async {
    calls.add('reset:$conversationId:${validDays ?? '-'}');
    await _wait();
    if (failNext != null) {
      final f = failNext!;
      failNext = null;
      return Err(f);
    }
    if (!admins.contains(conversationId)) return const Err(DeniedFailure());
    if (validDays != null && !{1, 7, 30}.contains(validDays)) {
      return const Err(DeniedFailure());
    }
    final token = 'T${(++_n).toString().padLeft(23, '0')}';
    final link = InviteLink(
      token: token,
      createdAt: DateTime.now(),
      expiresAt: validDays == null
          ? null
          : DateTime.now().add(Duration(days: validDays)),
    );
    _links[conversationId] = link;
    return Ok(link);
  }

  @override
  Future<Result<void>> turnOffInviteLink(String conversationId) async {
    calls.add('off:$conversationId');
    await _wait();
    if (failNext != null) {
      final f = failNext!;
      failNext = null;
      return Err(f);
    }
    if (!admins.contains(conversationId)) return const Err(DeniedFailure());
    _links.remove(conversationId);
    return const Ok(null);
  }

  @override
  Future<Result<InvitePreview>> previewInvite(String code) async {
    calls.add('preview:$code');
    await _wait();
    if (failNext != null) {
      final f = failNext!;
      failNext = null;
      return Err(f);
    }
    final conv = _links.entries
        .firstWhere(
          (e) => e.value.token == code,
          orElse: () =>
              MapEntry('', InviteLink(token: '', createdAt: DateTime.now())),
        )
        .key;
    if (conv.isEmpty) {
      return Err(const InviteLinkFailure(InviteLinkProblem.invalid));
    }
    final link = _links[conv]!;
    if (link.expiresAt != null && link.expiresAt!.isBefore(DateTime.now())) {
      return Err(const InviteLinkFailure(InviteLinkProblem.expired));
    }
    if (closedGroups.contains(conv)) {
      return Err(const InviteLinkFailure(InviteLinkProblem.closed));
    }
    if (removedFrom.contains(conv)) {
      return Err(const InviteLinkFailure(InviteLinkProblem.removed));
    }
    return Ok(
      InvitePreview(
        conversationId: conv,
        title: titles[conv] ?? 'Team',
        memberCount: members[conv] ?? 2,
        avatarPath: null,
      ),
    );
  }

  @override
  Future<Result<String>> joinByInvite(String code) async {
    calls.add('join:$code');
    await _wait();
    if (failNext != null) {
      final f = failNext!;
      failNext = null;
      return Err(f);
    }
    final conv = _links.entries
        .firstWhere(
          (e) => e.value.token == code,
          orElse: () =>
              MapEntry('', InviteLink(token: '', createdAt: DateTime.now())),
        )
        .key;
    if (conv.isEmpty) {
      return Err(const InviteLinkFailure(InviteLinkProblem.invalid));
    }
    final link = _links[conv]!;
    if (link.expiresAt != null && link.expiresAt!.isBefore(DateTime.now())) {
      return Err(const InviteLinkFailure(InviteLinkProblem.expired));
    }
    if (closedGroups.contains(conv)) {
      return Err(const InviteLinkFailure(InviteLinkProblem.closed));
    }
    if (removedFrom.contains(conv)) {
      return Err(const InviteLinkFailure(InviteLinkProblem.removed));
    }
    if (!joined.contains(conv)) joined.add(conv);
    return Ok(conv);
  }

  @override
  Future<Result<List<GroupEvent>>> joinEvents(String conversationId) async {
    calls.add('events:$conversationId');
    await _wait();
    if (failNext != null) {
      final f = failNext!;
      failNext = null;
      return Err(f);
    }
    return Ok(const []);
  }

  /// Helper to expire a stored link for a conversation.
  void expire(String conversationId) {
    final link = _links[conversationId];
    if (link != null) {
      _links[conversationId] = InviteLink(
        token: link.token,
        createdAt: link.createdAt,
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
    }
  }
}

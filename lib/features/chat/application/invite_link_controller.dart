import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/group_event.dart';
import '../domain/invite_link.dart';

Duration? _never(int retryCount, Object error) => null;

Future<T> _value<T>(Future<Result<T>> call) async => switch (await call) {
  Ok(:final value) => value,
  Err(:final failure) => throw failure,
};

final inviteLinkRepositoryProvider = Provider<InviteLinkRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// The group's invite link, for admins; null when there is none; AsyncError for anyone else.
final inviteLinkProvider = FutureProvider.autoDispose
    .family<InviteLink?, String>((ref, conversationId) {
      ref.watch(currentUserIdProvider);
      return _value(
        ref.read(inviteLinkRepositoryProvider).inviteLink(conversationId),
      );
    }, retry: _never);

/// What the join screen shows first; AsyncError holds the InviteLinkFailure or SearchLimitFailure.
final invitePreviewProvider = FutureProvider.autoDispose
    .family<InvitePreview, String>((ref, inviteCode) {
      ref.watch(currentUserIdProvider);
      return _value(
        ref.read(inviteLinkRepositoryProvider).previewInvite(inviteCode),
      );
    }, retry: _never);

/// The "X joined by link" lines of a group; every member may read; an error means no such lines.
final groupJoinEventsProvider = FutureProvider.autoDispose
    .family<List<GroupEvent>, String>((ref, conversationId) {
      ref.watch(currentUserIdProvider);
      return _value(
        ref.read(inviteLinkRepositoryProvider).joinEvents(conversationId),
      );
    }, retry: _never);

final inviteLinkControllerProvider = Provider<InviteLinkController>(
  InviteLinkController.new,
);

/// Admin changes to a group's invite link, and joining with one.
class InviteLinkController {
  InviteLinkController(this.ref);

  final Ref ref;

  /// Makes a new link (the old one stops working); [validDays] is null, 1, 7 or 30.
  Future<Result<InviteLink>> reset(
    String conversationId, {
    int? validDays,
  }) async {
    final r = await ref
        .read(inviteLinkRepositoryProvider)
        .resetInviteLink(conversationId, validDays: validDays);
    if (r is Ok) ref.invalidate(inviteLinkProvider(conversationId));
    return r;
  }

  /// Turns the link off: no link until an admin makes a new one.
  Future<Result<void>> turnOff(String conversationId) async {
    final r = await ref
        .read(inviteLinkRepositoryProvider)
        .turnOffInviteLink(conversationId);
    if (r is Ok) ref.invalidate(inviteLinkProvider(conversationId));
    return r;
  }

  /// Joins with what the person pasted (the bare code or a web address ending in it). Err(InviteLinkFailure(invalid)) when it holds no code, without asking the server. Ok = the group's conversation id.
  Future<Result<String>> join(String pasted) async {
    final code = inviteCodeFrom(pasted);
    if (code == null) {
      return const Err(InviteLinkFailure(InviteLinkProblem.invalid));
    }
    return ref.read(inviteLinkRepositoryProvider).joinByInvite(code);
  }

  /// Looks up the group behind [pasted] before joining; same refusal for a non-code.
  Future<Result<InvitePreview>> preview(String pasted) async {
    final code = inviteCodeFrom(pasted);
    if (code == null) {
      return const Err(InviteLinkFailure(InviteLinkProblem.invalid));
    }
    return ref.read(inviteLinkRepositoryProvider).previewInvite(code);
  }
}
